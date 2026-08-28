-- ============================================================
-- 02_functions.sql — Agente Hoteleiro (Hotel Sierra del Lago, Villa Carlos Paz)
--
-- Las 6 funciones RPC que el agente n8n llama como tools. Generado
-- directamente desde el proyecto Supabase <project-ref>. Requiere que
-- 01_schema.sql ya se haya ejecutado.
-- ============================================================

-- ------------------------------------------------------------
-- consultar_disponibilidad
-- Disponibilidad y precio discriminado por tipo de habitación. Nunca es un
-- contador: se calcula sumando reservas activas que se solapan con el rango
-- pedido (entrada < salida_existente AND salida > entrada_existente).
-- ------------------------------------------------------------
create or replace function public.consultar_disponibilidad(
  p_tipo text default null,
  p_entrada date default null,
  p_salida date default null
)
returns table (
  codigo text,
  nombre text,
  capacidad integer,
  total integer,
  ocupadas integer,
  disponibles integer,
  noches integer,
  tarifa_noche numeric,
  precio_por_habitacion numeric
)
language plpgsql
as $function$
begin
  return query
  select
    t.codigo, t.nombre, t.capacidad, t.cantidad as total,
    coalesce(oc.ocupadas, 0)::int,
    (t.cantidad - coalesce(oc.ocupadas, 0))::int,
    (p_salida - p_entrada)::int,
    t.tarifa_noche,
    (t.tarifa_noche * (p_salida - p_entrada))::numeric
  from tipos_habitacion t
  left join (
    select r.tipo_codigo, sum(r.cantidad_habitaciones)::int as ocupadas
    from reservas r
    where r.status in ('hold_sin_comprobante','hold_comprobante','confirmada')
      and not (r.status = 'hold_sin_comprobante' and r.expira_en < now())
      and p_entrada < r.fecha_salida
      and p_salida  > r.fecha_entrada
    group by r.tipo_codigo
  ) oc on oc.tipo_codigo = t.codigo
  where (p_tipo is null or t.codigo = p_tipo)
  order by t.tarifa_noche;
end;
$function$;

-- ------------------------------------------------------------
-- crear_reserva
-- Verifica disponibilidad e inserta en el mismo bloque (atómico, con
-- FOR UPDATE sobre tipos_habitacion). El precio siempre se calcula acá,
-- nunca lo calcula el LLM.
-- ------------------------------------------------------------
create or replace function public.crear_reserva(
  p_tipo text,
  p_nombre text,
  p_contacto text,
  p_entrada date,
  p_salida date,
  p_personas integer default 1,
  p_cantidad integer default 1,
  p_session_id text default null,
  p_channel text default 'chat',
  p_minutos_hold integer default 5
)
returns jsonb
language plpgsql
as $function$
declare
  v_tipo        tipos_habitacion%rowtype;
  v_ocupadas    int;
  v_disponibles int;
  v_noches      int;
  v_precio_hab  numeric(12,2);
  v_total       numeric(12,2);
  v_sena        numeric(12,2);
  v_codigo      text;
  v_id          bigint;
  v_cap_total   int;
begin
  if p_salida <= p_entrada then
    return jsonb_build_object('ok', false, 'error', 'fechas_invalidas',
      'mensaje', 'La fecha de salida debe ser posterior a la de entrada.');
  end if;

  if p_entrada < current_date then
    return jsonb_build_object('ok', false, 'error', 'fecha_pasada',
      'mensaje', 'No se pueden hacer reservas para fechas pasadas.');
  end if;

  if p_cantidad < 1 then
    return jsonb_build_object('ok', false, 'error', 'cantidad_invalida',
      'mensaje', 'La cantidad de habitaciones debe ser al menos 1.');
  end if;

  select * into v_tipo from tipos_habitacion where codigo = p_tipo for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'tipo_inexistente',
      'mensaje', 'Ese tipo de habitación no existe.');
  end if;

  -- Capacidad TOTAL considerando la cantidad de habitaciones
  v_cap_total := v_tipo.capacidad * p_cantidad;
  if p_personas > v_cap_total then
    return jsonb_build_object('ok', false, 'error', 'capacidad_excedida',
      'mensaje', format('%s %s admite(n) hasta %s persona(s) en total.',
                        p_cantidad, v_tipo.nombre, v_cap_total),
      'capacidad_total', v_cap_total);
  end if;

  -- Cuenta habitaciones ocupadas en el intervalo (sumando las cantidades)
  select coalesce(sum(r.cantidad_habitaciones), 0) into v_ocupadas
  from reservas r
  where r.tipo_codigo = p_tipo
    and r.status in ('hold_sin_comprobante', 'hold_comprobante', 'confirmada')
    and not (r.status = 'hold_sin_comprobante' and r.expira_en < now())
    and p_entrada < r.fecha_salida
    and p_salida  > r.fecha_entrada;

  v_disponibles := v_tipo.cantidad - v_ocupadas;

  if v_disponibles < p_cantidad then
    return jsonb_build_object(
      'ok', false,
      'error', 'sin_disponibilidad',
      'mensaje', format('Solo hay %s %s disponible(s) para esas fechas (pediste %s).',
                        v_disponibles, v_tipo.nombre, p_cantidad),
      'tipo', v_tipo.nombre,
      'solicitadas', p_cantidad,
      'disponibles', v_disponibles
    );
  end if;

  -- Precio: SIEMPRE calculado acá, nunca por el LLM
  v_noches     := p_salida - p_entrada;
  v_precio_hab := v_tipo.tarifa_noche * v_noches;
  v_total      := v_precio_hab * p_cantidad;
  v_sena       := round(v_total * 0.30, 2);

  v_codigo := 'SDL-' || upper(substr(md5(random()::text), 1, 6));

  insert into reservas (
    codigo_reserva, tipo_codigo, session_id, channel,
    huesped_nombre, huesped_contacto,
    fecha_entrada, fecha_salida, cantidad_personas, cantidad_habitaciones,
    monto_total, monto_sena, status, expira_en
  ) values (
    v_codigo, p_tipo, p_session_id, p_channel,
    p_nombre, p_contacto,
    p_entrada, p_salida, p_personas, p_cantidad,
    v_total, v_sena,
    'hold_sin_comprobante', now() + (p_minutos_hold || ' minutes')::interval
  ) returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'reserva_id', v_id,
    'codigo_reserva', v_codigo,
    'tipo', v_tipo.nombre,
    'cantidad_habitaciones', p_cantidad,
    'entrada', p_entrada,
    'salida', p_salida,
    'noches', v_noches,
    'personas', p_personas,
    'tarifa_noche', v_tipo.tarifa_noche,
    'precio_por_habitacion', v_precio_hab,
    'monto_total', v_total,
    'monto_sena', v_sena,
    'expira_en', now() + (p_minutos_hold || ' minutes')::interval,
    'minutos_hold', p_minutos_hold
  );
end;
$function$;

-- ------------------------------------------------------------
-- registrar_comprobante
-- El agente nunca confirma un pago: recibe el comprobante, lo retiene y pasa
-- la reserva a hold_comprobante (deja de expirar sola). La verificación final
-- es humana (confirmar_reserva) o vía webhook de gateway.
-- SECURITY DEFINER porque se llama desde el rol que ejecuta el tool HTTP; no
-- depende de policies de RLS para las tablas reservas/pagos.
-- ------------------------------------------------------------
create or replace function public.registrar_comprobante(
  p_codigo text,
  p_monto numeric default null,
  p_nro_operacion text default null,
  p_banco text default null,
  p_titular_destino text default null,
  p_cbu_destino text default null,
  p_fecha_operacion text default null,
  p_observacion text default null
)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_res       reservas%rowtype;
  v_duplicado boolean := false;
  v_fecha     date;
begin
  select * into v_res
  from reservas
  where upper(codigo_reserva) = upper(btrim(p_codigo))
  for update;

  if not found then
    return json_build_object(
      'ok', false,
      'motivo', 'reserva_no_encontrada',
      'mensaje', 'No existe una reserva con ese codigo. Pedile al huesped que lo verifique.',
      'codigo', p_codigo
    );
  end if;

  if v_res.status in ('cancelada', 'expirada', 'no_show') then
    return json_build_object(
      'ok', false,
      'motivo', 'reserva_no_vigente',
      'status', v_res.status,
      'mensaje', 'Esa reserva ya no esta vigente. Hay que tomar una reserva nueva antes de registrar el pago.',
      'codigo', v_res.codigo_reserva
    );
  end if;

  if v_res.status = 'confirmada' then
    return json_build_object(
      'ok', true,
      'motivo', 'ya_confirmada',
      'status', 'confirmada',
      'mensaje', 'La reserva ya estaba confirmada por el hotel.',
      'codigo', v_res.codigo_reserva
    );
  end if;

  if v_res.status = 'hold_comprobante' then
    v_duplicado := true;
  end if;

  if v_res.status = 'hold_sin_comprobante'
     and v_res.expira_en is not null
     and v_res.expira_en < now() then
    return json_build_object(
      'ok', false,
      'motivo', 'hold_expirado',
      'status', v_res.status,
      'mensaje', 'La reserva provisoria ya habia vencido. Avisale al huesped que vas a verificar si la habitacion sigue libre y volve a tomar la reserva.',
      'codigo', v_res.codigo_reserva
    );
  end if;

  -- Sin numero de operacion no hay como deduplicar: el indice unico parcial
  -- idx_pagos_operacion_unica solo aplica cuando nro_operacion no es null.
  -- Sin esta guarda, un comprobante ilegible podria retener varias reservas.
  -- La instruccion equivalente existe tambien en el prompt del agente, pero
  -- la garantia tiene que ser deterministica, no depender del LLM.
  if nullif(btrim(p_nro_operacion), '') is null then
    return json_build_object(
      'ok', false,
      'motivo', 'comprobante_ilegible',
      'codigo', v_res.codigo_reserva,
      'mensaje', 'El comprobante no trae numero de operacion legible. Sin ese dato no se puede registrar el pago ni retener la habitacion.'
    );
  end if;

  -- Reenvio del MISMO comprobante sobre la MISMA reserva: no es error.
  if exists (
       select 1 from pagos
       where reserva_id = v_res.id
         and nro_operacion = btrim(p_nro_operacion)
     )
  then
    v_duplicado := true;
  else
    begin
      v_fecha := nullif(btrim(p_fecha_operacion), '')::date;
    exception when others then
      v_fecha := null;
    end;

    -- El insert va ANTES del update de reservas a proposito: si el mismo
    -- nro_operacion ya fue usado en OTRA reserva, el indice unico parcial
    -- idx_pagos_operacion_unica levanta unique_violation y salimos sin
    -- retener la habitacion. Si el update viniera primero, la reserva
    -- quedaria retenida con un comprobante ya utilizado.
    begin
      insert into pagos (
        reserva_id,
        monto_reportado,
        metodo,
        nro_operacion,
        fecha_operacion,
        datos_extraidos,
        status,
        observacion
      ) values (
        v_res.id,
        p_monto,
        'transferencia',
        nullif(btrim(p_nro_operacion), ''),
        v_fecha,
        jsonb_build_object(
          'banco', p_banco,
          'titular_destino', p_titular_destino,
          'cbu_destino', p_cbu_destino,
          'fecha_operacion_texto', p_fecha_operacion
        ),
        'pendiente',
        nullif(btrim(p_observacion), '')
      );
    exception
      when unique_violation then
        return json_build_object(
          'ok', false,
          'motivo', 'comprobante_ya_usado',
          'codigo', v_res.codigo_reserva,
          'nro_operacion', btrim(p_nro_operacion),
          'mensaje', 'Ese numero de operacion ya fue registrado en otra reserva. La habitacion NO quedo retenida.'
        );
    end;
  end if;

  -- Solo se retiene la reserva despues de que el comprobante quedo guardado.
  update reservas
     set status    = 'hold_comprobante',
         expira_en = null
   where id = v_res.id;

  return json_build_object(
    'ok', true,
    'status', 'hold_comprobante',
    'codigo', v_res.codigo_reserva,
    'duplicado', v_duplicado,
    'monto_reportado', p_monto,
    'monto_sena_esperado', v_res.monto_sena,
    'monto_total', v_res.monto_total,
    'coincide_monto', case when p_monto is null or v_res.monto_sena is null then null
                           else (p_monto >= v_res.monto_sena) end,
    'mensaje', 'Comprobante registrado. La reserva quedo retenida y ya no expira. Falta la verificacion del equipo del hotel.'
  );
end;
$function$;

-- ------------------------------------------------------------
-- confirmar_reserva
-- Confirmación humana final. El agente nunca la llama por su cuenta.
-- ------------------------------------------------------------
create or replace function public.confirmar_reserva(p_codigo text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_res reservas%rowtype;
begin
  select * into v_res
  from reservas
  where upper(codigo_reserva) = upper(btrim(p_codigo))
  for update;

  if not found then
    return json_build_object('ok', false, 'motivo', 'reserva_no_encontrada');
  end if;

  if v_res.status in ('cancelada', 'expirada', 'no_show') then
    return json_build_object('ok', false, 'motivo', 'reserva_no_vigente', 'status', v_res.status);
  end if;

  update reservas
     set status    = 'confirmada',
         expira_en = null
   where id = v_res.id;

  update pagos set status = 'verificado' where reserva_id = v_res.id;

  return json_build_object('ok', true, 'status', 'confirmada', 'codigo', v_res.codigo_reserva);
end;
$function$;

-- ------------------------------------------------------------
-- expirar_holds_vencidos
-- Pensada para correr por schedule (pendiente: aún no hay un Schedule Trigger
-- llamándola). Libera holds sin comprobante cuyo expira_en ya pasó.
-- ------------------------------------------------------------
create or replace function public.expirar_holds_vencidos()
returns jsonb
language plpgsql
as $function$
declare
  v_afectadas int;
begin
  update reservas
  set status = 'expirada',
      updated_at = now(),
      notas = coalesce(notas || ' | ', '') || 'Expirada automáticamente por falta de comprobante.'
  where status = 'hold_sin_comprobante'
    and expira_en < now();

  get diagnostics v_afectadas = row_count;

  return jsonb_build_object(
    'ok', true,
    'reservas_expiradas', v_afectadas,
    'mensaje', format('%s reserva(s) expirada(s) y liberada(s).', v_afectadas)
  );
end;
$function$;

-- ------------------------------------------------------------
-- expirar_reserva_ahora
-- Expira una reserva puntual a mano. Uso de demo/soporte, no la llama el agente.
-- ------------------------------------------------------------
create or replace function public.expirar_reserva_ahora(p_codigo text)
returns jsonb
language plpgsql
as $function$
declare
  v_afectadas int;
begin
  update reservas
  set status = 'expirada',
      updated_at = now(),
      notas = coalesce(notas || ' | ', '') || 'Expirada manualmente (demo).'
  where codigo_reserva = p_codigo
    and status in ('hold_sin_comprobante', 'hold_comprobante');

  get diagnostics v_afectadas = row_count;

  return jsonb_build_object('ok', v_afectadas > 0, 'reservas_expiradas', v_afectadas);
end;
$function$;

-- ------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------

grant execute on function public.consultar_disponibilidad(text, date, date) to service_role;
grant execute on function public.crear_reserva(text, text, text, date, date, integer, integer, text, text, integer) to service_role;
grant execute on function public.registrar_comprobante(text, numeric, text, text, text, text, text, text) to service_role;
grant execute on function public.confirmar_reserva(text) to service_role;
grant execute on function public.expirar_holds_vencidos() to service_role;
grant execute on function public.expirar_reserva_ahora(text) to service_role;
