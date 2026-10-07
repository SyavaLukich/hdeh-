{ ============================================================================
  test_render.pas  --  тесты визуальной части без видеокарты

  Проверяется то, что обычно и ломает картинку:
    * раскладка вершин и экземпляров в памяти -- она должна совпадать
      со смещениями, которые передаются в glVertexAttribPointer;
    * геометрия примитивов: число вершин, единичные нормали, нормали
      наружу, обход треугольников против часовой стрелки (GL_CCW);
    * матрицы камеры и проекции;
    * отсечение по пирамиде видимости.

  OpenGL и GLFW не требуются.
  ============================================================================ }
program test_render;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, umath, ugeom, ucamera;

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

{ --------------------------------------------------------- раскладка памяти }
procedure test_layout;
var
  v: TVertex;
  inst: TInstance;
  base: PtrUInt;
begin
  WriteLn('-- раскладка данных для видеокарты');

  check(SizeOf(TVertex) = 32, 'вершина занимает 32 байта');
  base := PtrUInt(@v);
  check(PtrUInt(@v.px) - base = 0,  'смещение позиции = 0');
  check(PtrUInt(@v.nx) - base = 12, 'смещение нормали = 12');
  check(PtrUInt(@v.u)  - base = 24, 'смещение UV = 24');

  check(SizeOf(TInstance) = 80, 'экземпляр занимает 80 байт');
  base := PtrUInt(@inst);
  check(PtrUInt(@inst.model) - base = 0,  'смещение матрицы = 0');
  check(PtrUInt(@inst.color) - base = 64, 'смещение цвета = 64');

  check(SizeOf(TMat4) = 64, 'матрица 4x4 занимает 64 байта');
  check(SizeOf(TVec3) = 12, 'вектор занимает 12 байт');
end;

{ ------------------------------------------------------------- геометрия }

{ Треугольник обойдён против часовой стрелки, если его геометрическая
  нормаль совпадает по направлению с нормалями вершин. }
function winding_ok(const verts: TVertexArray; const idx: TIndexArray;
                    out badCount: Integer): Boolean;
var
  i: Integer;
  a, b, c, gn, vn: TVec3;
begin
  badCount := 0;
  i := 0;
  while i + 2 <= High(idx) do
  begin
    a := v3(verts[idx[i]].px, verts[idx[i]].py, verts[idx[i]].pz);
    b := v3(verts[idx[i+1]].px, verts[idx[i+1]].py, verts[idx[i+1]].pz);
    c := v3(verts[idx[i+2]].px, verts[idx[i+2]].py, verts[idx[i+2]].pz);
    gn := v3_cross(v3_sub(b, a), v3_sub(c, a));
    vn := v3(verts[idx[i]].nx, verts[idx[i]].ny, verts[idx[i]].nz);
    { вырожденных треугольников в буфере быть не должно вовсе }
    if v3_lensq(gn) < 1.0e-14 then Inc(badCount)
    else if v3_dot(gn, vn) <= 0 then Inc(badCount);
    Inc(i, 3);
  end;
  Result := badCount = 0;
end;

function normals_unit(const verts: TVertexArray): Boolean;
var
  i: Integer;
  l: Single;
begin
  Result := True;
  for i := 0 to High(verts) do
  begin
    l := v3_len(v3(verts[i].nx, verts[i].ny, verts[i].nz));
    if Abs(l - 1.0) > 1e-3 then Result := False;
  end;
end;

procedure test_geometry;
var
  verts: TVertexArray;
  idx: TIndexArray;
  box: TAABB;
  r, maxerr, d: Single;
  bad, i: Integer;
  wok: Boolean;
  p, n: TVec3;
begin
  WriteLn('-- геометрия примитивов');

  { ---- куб ---- }
  geom_box(v3(0.5, 0.5, 0.5), verts, idx);
  check(Length(verts) = 24, 'куб: 24 вершины (нормали разрывные по граням)');
  check(Length(idx) = 36, 'куб: 36 индексов (12 треугольников)');
  check(normals_unit(verts), 'куб: все нормали единичные');
  wok := winding_ok(verts, idx, bad);
  check(wok, Format('куб: обход против часовой у всех граней (плохих: %d)', [bad]));
  geom_bounds(verts, box, r);
  check_near(box.mn.x, -0.5, 1e-5, 'куб: габарит min');
  check_near(box.mx.y,  0.5, 1e-5, 'куб: габарит max');
  check_near(r, Sqrt(0.75), 1e-5, 'куб: радиус описанной сферы');

  { все вершины куба должны лежать ровно на гранях }
  maxerr := 0;
  for i := 0 to High(verts) do
  begin
    p := v3(verts[i].px, verts[i].py, verts[i].pz);
    d := Abs(v3_maxcomp(v3_abs(p)) - 0.5);
    if d > maxerr then maxerr := d;
  end;
  check_near(maxerr, 0.0, 1e-5, 'куб: вершины лежат на гранях');

  { ---- сфера ---- }
  geom_sphere(2.0, 24, 16, verts, idx);
  check(Length(verts) > 0, 'сфера: вершины построены');
  check(normals_unit(verts), 'сфера: все нормали единичные');
  wok := winding_ok(verts, idx, bad);
  check(wok, Format('сфера: обход против часовой (плохих: %d)', [bad]));
  maxerr := 0;
  for i := 0 to High(verts) do
  begin
    p := v3(verts[i].px, verts[i].py, verts[i].pz);
    n := v3(verts[i].nx, verts[i].ny, verts[i].nz);
    d := Abs(v3_len(p) - 2.0);
    if d > maxerr then maxerr := d;
    { нормаль сферы должна смотреть из центра }
    if v3_dot(n, p) <= 0 then maxerr := 99;
  end;
  check_near(maxerr, 0.0, 1e-4, 'сфера: все вершины на радиусе, нормали наружу');

  { ---- плоскость ---- }
  geom_plane(10, 4, verts, idx);
  check(Length(verts) = 25, 'плоскость 4x4: 25 вершин');
  check(Length(idx) = 96, 'плоскость 4x4: 96 индексов');
  wok := winding_ok(verts, idx, bad);
  check(wok, Format('плоскость: обход против часовой (плохих: %d)', [bad]));
  check_near(verts[0].ny, 1.0, 1e-5, 'плоскость: нормаль вверх');

  { ---- капсула ---- }
  geom_capsule(0.5, 1.0, 16, 12, verts, idx);
  check(normals_unit(verts), 'капсула: все нормали единичные');
  wok := winding_ok(verts, idx, bad);
  check(wok, Format('капсула: обход против часовой (плохих: %d)', [bad]));
  geom_bounds(verts, box, r);
  check_near(box.mx.y, 1.5, 1e-4, 'капсула: верх на halfheight + r');
  check_near(box.mn.y, -1.5, 1e-4, 'капсула: низ на -(halfheight + r)');
end;

{ ---------------------------------------------------------------- камера }
procedure test_camera;
var
  c: TCamera;
  p, ndc: TVec3;
  clip: array[0..3] of Single;
  m: TMat4;
  box: TAABB;

  procedure project(const v: TVec3);
  var k: Integer;
  begin
    for k := 0 to 3 do
      clip[k] := c.viewproj.m[k] * v.x + c.viewproj.m[4 + k] * v.y +
                 c.viewproj.m[8 + k] * v.z + c.viewproj.m[12 + k];
    if clip[3] <> 0 then
    begin
      ndc.x := clip[0] / clip[3];
      ndc.y := clip[1] / clip[3];
      ndc.z := clip[2] / clip[3];
    end;
  end;

begin
  WriteLn('-- камера и проекция');

  camera_init(c, v3(0, 0, 0));
  c.yaw := -PI_F * 0.5;    { смотрим вдоль -Z }
  c.pitch := 0;
  camera_update(c, 1600, 900);

  check_near(c.aspect, 16.0 / 9.0, 1e-5, 'соотношение сторон');
  check_near(c.forward_.z, -1.0, 1e-4, 'направление взгляда -Z');
  check_near(c.right.x, 1.0, 1e-4, 'правый вектор +X');
  check_near(c.up.y, 1.0, 1e-4, 'вектор вверх +Y');
  check_near(v3_dot(c.forward_, c.right), 0.0, 1e-5, 'базис камеры ортогонален');

  { точка ровно перед камерой должна попасть в центр экрана }
  project(v3(0, 0, -10));
  check_near(ndc.x, 0.0, 1e-5, 'центр экрана по X');
  check_near(ndc.y, 0.0, 1e-5, 'центр экрана по Y');
  check(clip[3] > 0, 'точка перед камерой: w > 0');

  { ближняя и дальняя плоскости отображаются в -1 и +1 }
  project(v3(0, 0, -c.znear));
  check_near(ndc.z, -1.0, 1e-3, 'ближняя плоскость -> z = -1');
  project(v3(0, 0, -c.zfar));
  check_near(ndc.z, 1.0, 1e-3, 'дальняя плоскость -> z = +1');

  { точка за спиной: отрицательный w, её обязан отбросить клиппер }
  project(v3(0, 0, 10));
  check(clip[3] < 0, 'точка за камерой: w < 0');

  { пирамида видимости }
  check(frustum_test_sphere(c.frustum, v3(0, 0, -10), 1.0),
        'пирамида: объект впереди виден');
  check(not frustum_test_sphere(c.frustum, v3(0, 0, 10), 1.0),
        'пирамида: объект сзади отсечён');
  check(not frustum_test_sphere(c.frustum, v3(0, 0, -600), 1.0),
        'пирамида: объект за дальней плоскостью отсечён');
  check(not frustum_test_sphere(c.frustum, v3(500, 0, -10), 1.0),
        'пирамида: объект сбоку отсечён');
  box.mn := v3(-1, -1, -11);
  box.mx := v3( 1,  1, -9);
  check(frustum_test_aabb(c.frustum, box), 'пирамида: AABB впереди виден');
  box.mn := v3(-1, -1, 9);
  box.mx := v3( 1,  1, 11);
  check(not frustum_test_aabb(c.frustum, box), 'пирамида: AABB сзади отсечён');

  { матрица экземпляра: поворот на 90 вокруг Y, масштаб 2, перенос }
  m := m4_compose(v3(10, 0, 0), q_from_axis(v3(0, 1, 0), PI_F * 0.5),
                  v3(2, 2, 2));
  p := m4_transform_point(m, v3(1, 0, 0));
  check_near(p.x, 10.0, 1e-4, 'матрица экземпляра: перенос X');
  check_near(p.z, -2.0, 1e-4, 'матрица экземпляра: поворот + масштаб');
  p := m4_transform_dir(m, v3(0, 1, 0));
  check_near(p.y, 2.0, 1e-4, 'матрица экземпляра: масштаб направления');

  { движение камеры в локальных осях }
  camera_init(c, v3(0, 0, 0));
  c.yaw := -PI_F * 0.5;
  c.pitch := 0;
  camera_update(c, 1600, 900);
  camera_move(c, v3(0, 0, 5));
  check_near(c.pos.z, -5.0, 1e-4, 'движение вперёд идёт по взгляду');

  { наклон камеры не должен переворачиваться }
  c.pitch := 10.0;
  camera_update(c, 1600, 900);
  check(c.pitch < PI_F * 0.5, 'наклон камеры ограничен');
end;

begin
  WriteLn('=== тесты визуальной части ===');
  test_layout;
  test_geometry;
  test_camera;
  WriteLn;
  WriteLn(Format('итого: %d пройдено, %d провалено', [g_pass, g_fail]));
  if g_fail > 0 then Halt(1);
end.
