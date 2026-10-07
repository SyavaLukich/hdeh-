{ ============================================================================
  test_physics.pas  --  консольные тесты математики, GJK/EPA и решателя

  Ничего не рисует и не требует OpenGL/GLFW, поэтому гоняется на любой
  машине и в CI:
      make test
  ============================================================================ }
program test_physics;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, umath, ugjk, uphysics;

var
  g_fail: Integer = 0;
  g_pass: Integer = 0;

procedure check(cond: Boolean; const name: string);
begin
  if cond then
  begin
    Inc(g_pass);
    WriteLn('  ok   ', name);
  end
  else
  begin
    Inc(g_fail);
    WriteLn('  FAIL ', name);
  end;
end;

procedure check_near(a, b, tol: Single; const name: string);
begin
  if Abs(a - b) <= tol then
  begin
    Inc(g_pass);
    WriteLn(Format('  ok   %s (%.5f ~ %.5f)', [name, a, b]));
  end
  else
  begin
    Inc(g_fail);
    WriteLn(Format('  FAIL %s: получено %.5f, ожидалось %.5f', [name, a, b]));
  end;
end;

function box_shape(hx, hy, hz: Single): TShape;
var
  pts: array[0..7] of TVec3;
  i: Integer;
  sx, sy, sz: Single;
begin
  for i := 0 to 7 do
  begin
    if (i and 1) <> 0 then sx := 1 else sx := -1;
    if (i and 2) <> 0 then sy := 1 else sy := -1;
    if (i and 4) <> 0 then sz := 1 else sz := -1;
    pts[i] := v3(hx * sx, hy * sy, hz * sz);
  end;
  Result := shape_hull(pts);
end;

{ ------------------------------------------------------------------ математика }
procedure test_math;
var
  q: TQuat;
  a, b: TVec3;
  m: TMat4;
  t1, t2: TVec3;
begin
  WriteLn('-- математика');

  check_near(v3_dot(v3(1, 2, 3), v3(4, 5, 6)), 32.0, 1e-5, 'скалярное произведение');
  a := v3_cross(v3(1, 0, 0), v3(0, 1, 0));
  check_near(a.z, 1.0, 1e-5, 'векторное произведение');
  check_near(v3_len(v3_norm(v3(3, 4, 12))), 1.0, 1e-5, 'нормировка');

  { поворот на 90 градусов вокруг Y переводит X в -Z }
  q := q_from_axis(v3(0, 1, 0), PI_F * 0.5);
  a := q_rotate(q, v3(1, 0, 0));
  check_near(a.x, 0.0, 1e-5, 'кватернион: x');
  check_near(a.z, -1.0, 1e-5, 'кватернион: z');

  { кватернион и матрица должны давать одинаковый результат }
  m := m4_from_quat(q);
  b := m4_transform_dir(m, v3(1, 0, 0));
  check_near(v3_dist(a, b), 0.0, 1e-5, 'кватернион = матрица');

  { обратная аффинная матрица }
  m := m4_mul(m4_translate(v3(5, -2, 7)), m4_from_quat(q));
  a := m4_transform_point(m4_mul(m4_inverse_affine(m), m), v3(1, 2, 3));
  check_near(v3_dist(a, v3(1, 2, 3)), 0.0, 1e-4, 'обратная аффинная матрица');

  { базис из нормали должен быть ортонормированным }
  v3_basis(v3_norm(v3(0.3, -0.8, 0.5)), t1, t2);
  check_near(v3_dot(t1, t2), 0.0, 1e-5, 'базис: ортогональность');
  check_near(v3_len(t1), 1.0, 1e-5, 'базис: длина 1');

  { slerp на середине пути: половина от 90 градусов -- это 45 }
  q := q_slerp(q_identity, q_from_axis(v3(0, 1, 0), PI_F * 0.5), 0.5);
  a := q_rotate(q, v3(1, 0, 0));
  check_near(a.x, Sqrt(0.5), 1e-4, 'slerp на середине: x');
  check_near(a.z, -Sqrt(0.5), 1e-4, 'slerp на середине: z');
end;

{ --------------------------------------------------------------------- GJK }
procedure test_gjk;
var
  s1, s2, bx: TShape;
  p1, p2: TPose;
  res: TGJKResult;
  pa, pb, n: TVec3;
  d, t: Single;
begin
  WriteLn('-- GJK / EPA');

  s1 := shape_sphere(1.0);
  s2 := shape_sphere(1.0);

  { явно расходятся }
  p1 := pose_make(v3(0, 0, 0), q_identity);
  p2 := pose_make(v3(5, 0, 0), q_identity);
  check(not gjk_intersect(s1, p1, s2, p2), 'сферы врозь: нет пересечения');
  d := gjk_distance(s1, p1, s2, p2, pa, pb);
  check_near(d, 3.0, 1e-3, 'расстояние между сферами');

  { явно пересекаются: центры на 1.5, радиусы по 1 -> глубина 0.5 }
  p2 := pose_make(v3(1.5, 0, 0), q_identity);
  check(gjk_intersect(s1, p1, s2, p2), 'сферы вместе: есть пересечение');
  check(gjk_collide(s1, p1, s2, p2, res), 'EPA отработал на сферах');
  check_near(res.depth, 0.5, 2e-2, 'EPA: глубина сфер');
  check_near(res.normal.x, 1.0, 2e-2, 'EPA: нормаль сфер');

  { касание ровно в точке }
  p2 := pose_make(v3(2.0, 0, 0), q_identity);
  check(not gjk_intersect(s1, p1, s2, p2) or True, 'сферы в касании: без падения');

  { куб против куба, перекрытие 0.1 по X }
  bx := box_shape(1, 1, 1);
  p1 := pose_make(v3(0, 0, 0), q_identity);
  p2 := pose_make(v3(1.9, 0, 0), q_identity);
  check(gjk_collide(bx, p1, bx, p2, res), 'кубы: пересечение найдено');
  check_near(res.depth, 0.1, 2e-2, 'EPA: глубина кубов');
  check_near(Abs(res.normal.x), 1.0, 2e-2, 'EPA: нормаль кубов по X');

  { разъехавшиеся кубы }
  p2 := pose_make(v3(2.5, 0, 0), q_identity);
  check(not gjk_intersect(bx, p1, bx, p2), 'кубы врозь');
  d := gjk_distance(bx, p1, bx, p2, pa, pb);
  check_near(d, 0.5, 1e-2, 'расстояние между кубами');

  { повёрнутый куб против сферы }
  p2 := pose_make(v3(1.6, 0, 0), q_from_euler(0.4, 0.7, 0.2));
  check(gjk_collide(bx, p1, s1, p2, res) = gjk_intersect(bx, p1, s1, p2),
        'куб/сфера: collide и intersect согласованы');

  { капсула, лежащая на кубе }
  s2 := shape_capsule(0.5, 1.0);
  p2 := pose_make(v3(0, 2.3, 0), q_identity);
  check(gjk_collide(bx, p1, s2, p2, res), 'капсула касается куба');
  check_near(res.normal.y, 1.0, 5e-2, 'нормаль капсулы вверх');

  { луч в сферу }
  p1 := pose_make(v3(0, 0, 0), q_identity);
  check(gjk_raycast(s1, p1, v3(-10, 0, 0), v3(1, 0, 0), 100, t, n),
        'луч попал в сферу');
  check_near(t, 9.0, 1e-2, 'длина луча до сферы');
  check(not gjk_raycast(s1, p1, v3(-10, 5, 0), v3(1, 0, 0), 100, t, n),
        'луч мимо сферы');
end;

{ ---------------------------------------------------------------- симуляция }
function is_finite_body(i: Integer): Boolean;
var p: TVec3;
begin
  p := g_bodies[i].pos;
  Result := (Abs(p.x) < 1e6) and (Abs(p.y) < 1e6) and (Abs(p.z) < 1e6)
            and (p.x = p.x) and (p.y = p.y) and (p.z = p.z);
end;

procedure test_simulation;
const
  DT = 1.0 / 120.0;
var
  i, k, floor_id, box_id, ball_id: Integer;
  ids: array[0..4] of Integer;
  allfinite, allsleep: Boolean;
  maxTilt: Single;
  up: TVec3;
begin
  WriteLn('-- симуляция');

  { ----- один ящик падает на пол ----- }
  phys_init;
  floor_id := phys_add_body(box_shape(50, 1, 50), v3(0, -1, 0), q_identity, 0);
  phys_set_material(floor_id, 0.9, 0.0);
  box_id := phys_add_body(box_shape(0.5, 0.5, 0.5), v3(0, 4, 0), q_identity, 1.0);

  for i := 1 to 480 do phys_step(DT);     { 4 секунды }

  check(is_finite_body(box_id), 'ящик не улетел в бесконечность');
  check_near(g_bodies[box_id].pos.y, 0.5, 0.03, 'ящик лежит на полу');
  check_near(g_bodies[box_id].pos.x, 0.0, 0.05, 'ящик не уполз по X');
  check(BF_SLEEPING in g_bodies[box_id].flags, 'ящик заснул');

  { ----- стопка из пяти ящиков ----- }
  phys_init;
  floor_id := phys_add_body(box_shape(50, 1, 50), v3(0, -1, 0), q_identity, 0);
  phys_set_material(floor_id, 0.9, 0.0);
  for k := 0 to 4 do
  begin
    ids[k] := phys_add_body(box_shape(0.5, 0.5, 0.5),
                            v3(0, 0.5 + k * 1.02, 0), q_identity, 1.0);
    phys_set_material(ids[k], 0.7, 0.0);
  end;

  for i := 1 to 720 do phys_step(DT);     { 6 секунд }

  allfinite := True;
  allsleep := True;
  maxTilt := 0;
  for k := 0 to 4 do
  begin
    if not is_finite_body(ids[k]) then allfinite := False;
    if not (BF_SLEEPING in g_bodies[ids[k]].flags) then allsleep := False;
    up := q_rotate(g_bodies[ids[k]].orient, v3(0, 1, 0));
    if 1.0 - up.y > maxTilt then maxTilt := 1.0 - up.y;
  end;

  check(allfinite, 'стопка: все тела конечны');
  check(allsleep, 'стопка: вся стопка заснула');
  check(maxTilt < 0.05, 'стопка: ящики не завалились');
  for k := 0 to 4 do
    check_near(g_bodies[ids[k]].pos.y, 0.5 + k * 1.0, 0.08,
               Format('стопка: высота ящика %d', [k]));

  { ----- шар с отскоком ----- }
  phys_init;
  floor_id := phys_add_body(box_shape(50, 1, 50), v3(0, -1, 0), q_identity, 0);
  phys_set_material(floor_id, 0.5, 0.6);
  ball_id := phys_add_body(shape_sphere(0.5), v3(0, 6, 0), q_identity, 2.0);
  phys_set_material(ball_id, 0.4, 0.6);

  for i := 1 to 120 do phys_step(DT);
  check(g_bodies[ball_id].pos.y < 6.0, 'шар падает');
  for i := 1 to 600 do phys_step(DT);
  check_near(g_bodies[ball_id].pos.y, 0.5, 0.06, 'шар успокоился на полу');

  { ----- стрельба: быстрое тело не проваливается сквозь пол ----- }
  phys_init;
  floor_id := phys_add_body(box_shape(50, 1, 50), v3(0, -1, 0), q_identity, 0);
  ball_id := phys_add_body(shape_sphere(0.4), v3(0, 10, 0), q_identity, 5.0);
  phys_apply_impulse(ball_id, v3(0, -250, 0), g_bodies[ball_id].pos);
  for i := 1 to 600 do phys_step(DT);
  check(g_bodies[ball_id].pos.y > 0.2, 'быстрый шар не провалился сквозь пол');

  { ----- трение: ящик на наклонно толкаемой поверхности тормозит ----- }
  phys_init;
  floor_id := phys_add_body(box_shape(50, 1, 50), v3(0, -1, 0), q_identity, 0);
  phys_set_material(floor_id, 0.9, 0.0);
  box_id := phys_add_body(box_shape(0.5, 0.5, 0.5), v3(0, 0.5, 0), q_identity, 1.0);
  phys_set_material(box_id, 0.9, 0.0);
  for i := 1 to 60 do phys_step(DT);
  phys_apply_impulse(box_id, v3(6, 0, 0), g_bodies[box_id].pos);
  for i := 1 to 600 do phys_step(DT);
  check(v3_len(g_bodies[box_id].linvel) < 0.1, 'трение остановило ящик');
  check(g_bodies[box_id].pos.x > 0.05, 'ящик всё-таки проехал вперёд');

  { ----- луч по миру ----- }
  phys_init;
  floor_id := phys_add_body(box_shape(50, 1, 50), v3(0, -1, 0), q_identity, 0);
  box_id := phys_add_body(box_shape(1, 1, 1), v3(0, 5, 0), q_identity, 0);
  phys_step(DT);
  check(phys_raycast(v3(0, 20, 0), v3(0, -1, 0), 100).body = box_id,
        'луч сверху нашёл верхний ящик');
end;

{ --------------------------------------------------------------- нагрузка }
procedure test_stress;
const
  DT = 1.0 / 120.0;
var
  i, k, x, z, n: Integer;
  t0, t1: TDateTime;
  ms: Double;
  ok: Boolean;
begin
  WriteLn('-- нагрузочный прогон');
  phys_init;
  phys_add_body(box_shape(60, 1, 60), v3(0, -1, 0), q_identity, 0);

  n := 0;
  for k := 0 to 7 do
    for x := 0 to 9 do
      for z := 0 to 9 do
      begin
        phys_add_body(box_shape(0.5, 0.5, 0.5),
                      v3(-5 + x * 1.05, 0.5 + k * 1.05, -5 + z * 1.05),
                      q_identity, 1.0);
        Inc(n);
      end;

  t0 := Now;
  for i := 1 to 240 do phys_step(DT);
  t1 := Now;
  ms := (t1 - t0) * 24 * 60 * 60 * 1000;

  ok := True;
  for i := 0 to g_nbodies - 1 do
    if not is_finite_body(i) then ok := False;

  WriteLn(Format('     тел: %d, шагов: 240, всего: %.0f мс, на шаг: %.2f мс',
                 [g_nbodies, ms, ms / 240]));
  WriteLn(Format('     пар широкой фазы: %d, точек контакта: %d, не спят: %d',
                 [g_stat_pairs, g_stat_contacts, g_stat_awake]));
  check(ok, Format('нагрузка: %d тел остались конечными', [n]));
  check(ms / 240 < 50.0, 'нагрузка: шаг укладывается в 50 мс');
end;

begin
  WriteLn('=== тесты движка ===');
  test_math;
  test_gjk;
  test_simulation;
  test_stress;
  WriteLn;
  WriteLn(Format('итого: %d пройдено, %d провалено', [g_pass, g_fail]));
  if g_fail > 0 then Halt(1);
end.
