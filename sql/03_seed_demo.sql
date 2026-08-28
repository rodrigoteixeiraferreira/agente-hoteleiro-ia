-- ============================================================
-- 03_seed_demo.sql — Agente Hoteleiro (Hotel Sierra del Lago, Villa Carlos Paz)
--
-- Inventario del hotel de demostración (ficticio). No incluye reservas,
-- pagos ni escalaciones: esos son datos operativos, no seed. Requiere que
-- 01_schema.sql ya se haya ejecutado.
-- ============================================================

insert into public.tipos_habitacion (codigo, nombre, capacidad, cantidad, tarifa_noche, descripcion) values
  ('individual',     'Habitación Individual',     1, 2, 35000.00,  'Para 1 persona, cama individual, baño privado, wifi, TV, aire acondicionado y desayuno.'),
  ('doble_estandar', 'Habitación Doble Estándar',  2, 6, 52000.00,  'Para 2 personas, cama matrimonial o dos individuales, frigobar, wifi, TV, aire y desayuno.'),
  ('doble_superior', 'Habitación Doble Superior',  2, 4, 68000.00,  'Para 2 personas, más amplia, con vista al lago y balcón privado.'),
  ('familiar',       'Habitación Familiar',        4, 3, 85000.00,  'Hasta 4 personas, una cama matrimonial y dos individuales.'),
  ('suite',          'Suite',                      2, 2, 120000.00, 'La categoría más amplia: living separado, vista al lago, balcón e hidromasaje.')
on conflict (codigo) do nothing;
