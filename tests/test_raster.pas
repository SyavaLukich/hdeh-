{ ============================================================================
  test_raster.pas  --  проверка программного растеризатора по спецификации GL

  Зачем это нужно. Превью рисует не OpenGL, а модуль usoftgl -- независимая
  реализация того же конвейера. Сама по себе она ничего не доказывает:
  если в ней перепутан знак отсечения задних граней или сломана
  перспективная коррекция, картинка будет выглядеть правдоподобно и молча
  врать. Поэтому растеризатор сверяется не сам с собой, а с формулами из
  спецификации OpenGL, посчитанными здесь независимо и аналитически.

  Проверяется:
    * отображение NDC в окно (включая направление оси Y);
    * знак отсечения задних граней относительно правила GL_CCW;
    * тест глубины: результат не зависит от порядка отрисовки;
    * перспективная коррекция -- сверка с пересечением луча и плоскости,
      плюс доказательство, что аффинная интерполяция дала бы заметно другое;
    * отсечение по ближней плоскости;
    * сглаживание сетки через fwidth.
  ============================================================================ }
program test_raster;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugeom, ucamera, usoftgl;

const
  W = 320;
  H = 240;

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

{ Камера в начале координат, взгляд вдоль -Z, без наклона. }
procedure setup_camera;
begin
  camera_init(sg_cam, v3(0, 0, 0));
  sg_cam.yaw := -PI_F * 0.5;
  sg_cam.pitch := 0;
  sg_cam.fov := 90.0 * DEG2RAD;
  sg_cam.znear := 0.1;
  sg_cam.zfar := 1000.0;
  camera_update(sg_cam, W, H);
end;

{ Треугольник из трёх мировых точек с заданной нормалью. }
procedure make_tri(const a, b, c, n: TVec3;
                   out verts: TVertexArray; out idx: TIndexArray);
  procedure put(i: Integer; const p: TVec3);
  begin
    verts[i].px := p.x; verts[i].py := p.y; verts[i].pz := p.z;
    verts[i].nx := n.x; verts[i].ny := n.y; verts[i].nz := n.z;
    verts[i].u := 0; verts[i].v := 0;
  end;
begin
  SetLength(verts, 3);
  SetLength(idx, 3);
  put(0, a); put(1, b); put(2, c);
  idx[0] := 0; idx[1] := 1; idx[2] := 2;
end;

function white: TVec4;
begin
  Result := v4_make(1, 1, 1, 1);
end;

{ ===================================================== отображение в окно }
procedure test_viewport;
var
  sx, sy, sz, iw, halfw: Single;
begin
  WriteLn('-- отображение NDC в оконные координаты');
  setup_camera;
  sg_init(W, H, v3(0, 0, 0));

  { Точка прямо по курсу обязана попасть в центр кадра. }
  check(sg_to_window(v3(0, 0, -10), sx, sy, sz, iw), 'точка впереди проецируется');
  check_near(sx, W / 2, 1e-3, 'центр кадра по X');
  check_near(sy, H / 2, 1e-3, 'центр кадра по Y');

  { Правый край: при fov 90 по вертикали половина высоты усечённой
    пирамиды на расстоянии d равна d, а половина ширины -- d*aspect. }
  halfw := 10.0 * (W / H);
  sg_to_window(v3(halfw, 0, -10), sx, sy, sz, iw);
  check_near(sx, W, 1e-2, 'правый край кадра -> x = W');

  { Верх кадра: в NDC это y = +1, а в окне -- строка 0. Если перепутать
    направление оси Y, картинка окажется вверх ногами. }
  sg_to_window(v3(0, 10, -10), sx, sy, sz, iw);
  check_near(sy, 0, 1e-2, 'верх кадра -> y = 0 (ось Y вниз)');
  sg_to_window(v3(0, -10, -10), sx, sy, sz, iw);
  check_near(sy, H, 1e-2, 'низ кадра -> y = H');

  { Глубина: ближняя и дальняя плоскости дают -1 и +1. }
  sg_to_window(v3(0, 0, -sg_cam.znear), sx, sy, sz, iw);
  check_near(sz, -1.0, 1e-3, 'ближняя плоскость -> z = -1');
  sg_to_window(v3(0, 0, -sg_cam.zfar), sx, sy, sz, iw);
  check_near(sz, 1.0, 1e-3, 'дальняя плоскость -> z = +1');

  { 1/w линейна в экранном пространстве -- на этом держится коррекция. }
  check_near(iw, 1.0 / sg_cam.zfar, 1e-6, 'invw = 1/расстояние');
end;

{ ============================================== отсечение задних граней }
procedure test_culling;
var
  verts: TVertexArray;
  idx: TIndexArray;
  a, b, c: TVec3;
  sxa, sya, sxb, syb, sxc, syc, sz, iw: Single;
  cross_yup: Single;
  front, back: Integer;
begin
  WriteLn('-- отсечение задних граней (правило GL_CCW)');
  setup_camera;

  { Треугольник перед камерой, нормаль на камеру. }
  a := v3(-2, -2, -10);
  b := v3( 2, -2, -10);
  c := v3( 0,  2, -10);

  { Считаем обход независимо: переводим в NDC и смотрим знак векторного
    произведения при оси Y, направленной ВВЕРХ -- как определено в GL. }
  sg_init(W, H, v3(0, 0, 0));
  sg_to_window(a, sxa, sya, sz, iw);
  sg_to_window(b, sxb, syb, sz, iw);
  sg_to_window(c, sxc, syc, sz, iw);
  { возвращаем ось Y вверх }
  sya := H - sya; syb := H - syb; syc := H - syc;
  cross_yup := (sxb - sxa) * (syc - sya) - (syb - sya) * (sxc - sxa);
  check(cross_yup > 0, 'контрольный треугольник обойдён против часовой');

  make_tri(a, b, c, v3(0, 0, 1), verts, idx);
  sg_init(W, H, v3(0, 0, 0));
  sg_draw(verts, idx, m4_identity, white);
  front := sg_pixels;

  { Тот же треугольник с обратным обходом -- задняя грань. }
  make_tri(a, c, b, v3(0, 0, 1), verts, idx);
  sg_init(W, H, v3(0, 0, 0));
  sg_draw(verts, idx, m4_identity, white);
  back := sg_pixels;

  check(front > 1000, Format('лицевая грань нарисована (%d пикселей)', [front]));
  check(back = 0, Format('задняя грань отброшена (%d пикселей)', [back]));
end;

{ ============================================================== глубина }
procedure test_depth;
var
  vfar, vnear: TVertexArray;
  ifar, inear: TIndexArray;
  cx, cy: Integer;
  c1, c2: TPixel;
  d1, d2, zexp: Single;
  sx, sy, sz, iw: Single;
begin
  WriteLn('-- тест глубины');
  setup_camera;
  cx := W div 2;
  cy := H div 2;

  make_tri(v3(-8, -8, -20), v3(8, -8, -20), v3(0, 8, -20), v3(0, 0, 1),
           vfar, ifar);
  make_tri(v3(-4, -4, -5), v3(4, -4, -5), v3(0, 4, -5), v3(0, 0, 1),
           vnear, inear);

  { порядок "дальний, потом ближний" }
  sg_init(W, H, v3(0, 0, 0));
  sg_draw(vfar, ifar, m4_identity, v4_make(1, 0, 0, 1));
  sg_draw(vnear, inear, m4_identity, v4_make(0, 0, 1, 1));
  c1 := sg_at(cx, cy);
  d1 := sg_depth_at(cx, cy);

  { обратный порядок -- результат обязан совпасть }
  sg_init(W, H, v3(0, 0, 0));
  sg_draw(vnear, inear, m4_identity, v4_make(0, 0, 1, 1));
  sg_draw(vfar, ifar, m4_identity, v4_make(1, 0, 0, 1));
  c2 := sg_at(cx, cy);
  d2 := sg_depth_at(cx, cy);

  check(c1.b > c1.r, 'ближний треугольник победил (порядок 1)');
  check(c2.b > c2.r, 'ближний треугольник победил (порядок 2)');
  check_near(d1, d2, 1e-6, 'глубина не зависит от порядка отрисовки');

  sg_to_window(v3(0, 0, -5), sx, sy, sz, iw);
  zexp := sz;
  check_near(d1, zexp, 1e-5, 'в буфере глубины лежит z из NDC');
end;

{ ========================================= перспективная коррекция }
procedure test_perspective;
var
  verts: TVertexArray;
  idx: TIndexArray;
  px, py: Integer;
  ndcx, ndcy, tanf: Single;
  dir, hit, got, affine: TVec3;
  t: Single;
  a, b, c: TVec3;
  sxa, sya, sxb, syb, sxc, syc, sz, iwa, iwb, iwc: Single;
  w0, w1, w2, den: Single;
begin
  WriteLn('-- перспективно корректная интерполяция');
  setup_camera;
  sg_init(W, H, v3(0, 0, 0));

  { Большой треугольник в плоскости пола y = -2, сильно уходящий вдаль.
    Обход подобран так, чтобы нормаль смотрела вверх, на камеру. }
  a := v3(-60, -2, -200);
  b := v3(-60, -2,   -2);
  c := v3( 60, -2,   -2);
  make_tri(a, b, c, v3(0, 1, 0), verts, idx);
  sg_draw(verts, idx, m4_identity, white);

  { Берём пиксель в нижней части кадра и считаем аналитически, куда
    смотрит луч из камеры и где он протыкает плоскость y = -2. }
  px := W div 2;
  py := (H * 3) div 4;
  ndcx := ((px + 0.5) / W) * 2 - 1;
  ndcy := 1 - ((py + 0.5) / H) * 2;
  tanf := Tan(sg_cam.fov * 0.5);
  dir := v3_norm(v3(ndcx * tanf * sg_cam.aspect, ndcy * tanf, -1));
  t := (-2 - sg_cam.pos.y) / dir.y;
  hit := v3_mad(sg_cam.pos, dir, t);

  got := sg_wpos[py * W + px];
  check(v3_lensq(got) > 0, 'пиксель закрашен');
  check_near(v3_dist(got, hit), 0.0, 2e-3,
             'мировая точка совпала с пересечением луча и плоскости');

  { Контрольный вопрос: а отличалась бы аффинная интерполяция?
    Если нет, тест выше ничего не доказывает. }
  sg_to_window(a, sxa, sya, sz, iwa);
  sg_to_window(b, sxb, syb, sz, iwb);
  sg_to_window(c, sxc, syc, sz, iwc);
  den := (sxb - sxa) * (syc - sya) - (syb - sya) * (sxc - sxa);
  w0 := ((sxb - px - 0.5) * (syc - py - 0.5) -
         (syb - py - 0.5) * (sxc - px - 0.5)) / den;
  w1 := ((sxc - px - 0.5) * (sya - py - 0.5) -
         (syc - py - 0.5) * (sxa - px - 0.5)) / den;
  w2 := 1 - w0 - w1;
  affine := v3_add(v3_add(v3_mul(a, w0), v3_mul(b, w1)), v3_mul(c, w2));
  check(v3_dist(affine, hit) > 0.5,
        Format('аффинная интерполяция дала бы ошибку %.2f м -- значит, проверка выше не пустая',
               [v3_dist(affine, hit)]));
end;

{ ====================================== отсечение по ближней плоскости }
procedure test_near_clip;
var
  verts: TVertexArray;
  idx: TIndexArray;
  i, behind: Integer;
  wp: TVec3;
begin
  WriteLn('-- отсечение по ближней плоскости');
  setup_camera;
  sg_init(W, H, v3(0, 0, 0));

  { Одна вершина за спиной камеры (z = +5), две впереди. }
  make_tri(v3(-5, -3, 5), v3(5, -3, -10), v3(0, 5, -10), v3(0, 0, 1),
           verts, idx);
  sg_draw(verts, idx, m4_identity, white);

  check(sg_pixels > 500,
        Format('треугольник, пересекающий ближнюю плоскость, нарисован (%d пикселей)',
               [sg_pixels]));

  { Ни один закрашенный пиксель не должен ссылаться на точку позади камеры. }
  behind := 0;
  for i := 0 to W * H - 1 do
  begin
    wp := sg_wpos[i];
    if v3_lensq(wp) = 0 then Continue;
    if v3_dot(v3_sub(wp, sg_cam.pos), sg_cam.forward_) < sg_cam.znear - 1e-3 then
      Inc(behind);
  end;
  check(behind = 0, Format('нет пикселей из-за ближней плоскости (%d)', [behind]));
end;

{ ================================================ сглаживание сетки }
procedure test_grid;
var
  onLine, between, varNear, varFar: Single;
begin
  WriteLn('-- сетка из шейдера FS_LIT');

  { Ровно на линии (целая координата) и при мелком шаге -- тёмный край. }
  onLine := sg_grid(0.0, 0.0, 0.01, 0.01);
  check_near(onLine, 0.78, 1e-3, 'на линии сетки цвет 0.78');

  { Далеко от линии -- чистый цвет. }
  between := sg_grid(0.5, 0.5, 0.01, 0.01);
  check_near(between, 1.0, 1e-3, 'между линиями цвет 1.0');

  { Главное свойство fwidth: при сильном уменьшении результат перестаёт
    зависеть от координаты, то есть сетка превращается в ровную заливку и
    муара на горизонте не возникает. (Заливка получается цвета линии,
    0.78 -- так устроена эта функция в шейдере, и превью обязано вести
    себя так же.) }
  varNear := Abs(sg_grid(0.0, 0.0, 0.01, 0.01) - sg_grid(0.5, 0.5, 0.01, 0.01));
  varFar  := Abs(sg_grid(0.0, 0.0, 4.00, 4.00) - sg_grid(0.5, 0.5, 4.00, 4.00));
  check(varNear > 0.2,
        Format('вблизи сетка хорошо различима (размах %.3f)', [varNear]));
  check(varFar < varNear / 5,
        Format('вдали размах падает в %.0f раз -- муара не будет (%.3f против %.3f)',
               [varNear / varFar, varFar, varNear]));
end;

begin
  WriteLn('=== тесты программного растеризатора ===');
  test_viewport;
  test_culling;
  test_depth;
  test_perspective;
  test_near_clip;
  test_grid;
  WriteLn;
  WriteLn(Format('итого: %d пройдено, %d провалено', [g_pass, g_fail]));
  if g_fail > 0 then Halt(1);
end.
