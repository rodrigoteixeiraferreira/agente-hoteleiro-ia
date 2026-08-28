-- ============================================================
-- retener_con_saldo — Hotel Sierra del Lago
-- ============================================================
-- Retiene una reserva usando el excedente ya reportado en la MISMA sesion,
-- sin exigir una transferencia nueva.
--
-- Por que existe: si el huesped ya mando comprobantes que cubren de sobra la
-- sena de una reserva, exigirle otra transferencia por una segunda reserva es
-- perder la venta por una formalidad. Pero la cuenta NO puede hacerla el
-- modelo de lenguaje: la hace esta funcion, sobre la tabla pagos, de forma
-- deterministica y auditable.
--
-- Lo que NO hace: confirmar el pago. La verificacion de los ingresos reales
-- sigue siendo humana (confirmar_reserva). Los montos de pagos son lo que el
-- huesped REPORTO, no lo que el hotel COBRO.
-- ============================================================

create or replace function public.retener_con_saldo(p_codigo text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_res           reservas%rowtype;
  v_reportado     numeric := 0;
  v_comprometido  numeric := 0;
  v_saldo         numeric := 0;
begin
  select * into v_res
  from reservas
  where upper(codigo_reserva) = upper(btrim(p_codigo))
  for update;

  if not found then
    return json_build_object(
      'ok', false, 'motivo', 'reserva_no_encontrada',
      'mensaje', 'No existe una reserva con ese codigo.');
  end if;

  if v_res.status in ('cancelada', 'expirada', 'no_show') then
    return json_build_object(
      'ok', false, 'motivo', 'reserva_no_vigente', 'status', v_res.status,
      'mensaje', 'Esa reserva ya no esta vigente. Hay que tomar una reserva nueva.');
  end if;

  if v_res.status in ('hold_comprobante', 'confirmada') then
    return json_build_object(
      'ok', true, 'motivo', 'ya_retenida', 'status', v_res.status,
      'codigo', v_res.codigo_reserva,
      'mensaje', 'Esa reserva ya estaba retenida.');
  end if;

  if v_res.session_id is null then
    return json_build_object(
      'ok', false, 'motivo', 'sin_sesion',
      'mensaje', 'La reserva no tiene sesion asociada: no se puede aplicar saldo.');
  end if;

  -- Todo lo que el huesped REPORTO en esta sesion, sin importar a que reserva
  -- lo adjunto. Los comprobantes rechazados no suman.
  select coalesce(sum(p.monto_reportado), 0) into v_reportado
  from pagos p
  join reservas r on r.id = p.reserva_id
  where r.session_id = v_res.session_id
    and coalesce(p.status, '') <> 'rechazado';

  -- Lo que ya esta comprometido: senas de reservas retenidas o confirmadas.
  -- Una reserva cancelada libera su sena, pero su pago sigue contando arriba.
  select coalesce(sum(r.monto_sena), 0) into v_comprometido
  from reservas r
  where r.session_id = v_res.session_id
    and r.status in ('hold_comprobante', 'confirmada');

  v_saldo := v_reportado - v_comprometido;

  if v_saldo < v_res.monto_sena then
    return json_build_object(
      'ok', false,
      'motivo', 'saldo_insuficiente',
      'codigo', v_res.codigo_reserva,
      'saldo_disponible', v_saldo,
      'sena_requerida', v_res.monto_sena,
      'falta', v_res.monto_sena - v_saldo,
      'mensaje', 'El saldo reportado en esta conversacion no alcanza para cubrir la sena de esta reserva.');
  end if;

  update reservas
     set status    = 'hold_comprobante',
         expira_en = null,
         updated_at = now(),
         notas = coalesce(notas || ' | ', '')
                 || format('Retenida con saldo a favor de la sesion (%s reportado, %s comprometido). Sin transferencia propia: verificar asignacion.',
                           v_reportado, v_comprometido)
   where id = v_res.id;

  return json_build_object(
    'ok', true,
    'motivo', 'retenida_con_saldo',
    'status', 'hold_comprobante',
    'codigo', v_res.codigo_reserva,
    'sena_aplicada', v_res.monto_sena,
    'saldo_antes', v_saldo,
    'saldo_restante', v_saldo - v_res.monto_sena,
    'mensaje', 'Reserva retenida aplicando el saldo ya reportado en esta conversacion. Falta la verificacion del equipo del hotel.');
end;
$function$;

grant execute on function public.retener_con_saldo(text) to service_role;


-- ------------------------------------------------------------
-- Consulta de apoyo: el estado de cuenta de una sesion.
-- Es lo mismo que ve el humano cuando revisa el caso.
-- ------------------------------------------------------------
-- select r.codigo_reserva, r.status, r.monto_sena, p.nro_operacion, p.monto_reportado, p.status
-- from reservas r left join pagos p on p.reserva_id = r.id
-- where r.session_id = 'SESSION_ID_ACA'
-- order by r.id, p.id;
