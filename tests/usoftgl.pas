{ ============================================================================
  usoftgl.pas  --  программный растеризатор для проверки без видеокарты

  ВАЖНО О СТАТУСЕ ЭТОГО МОДУЛЯ.
  Это НЕ эталонная реализация OpenGL и не доказательство того, что движок
  рисует правильно. Это независимая реализация того же конвейера, написанная
  по спецификации OpenGL. Она позволяет увидеть сцену и поймать ошибки в
  данных (геометрия, нормали, обход, матрицы, отсечение), но совпадение
  пиксель-в-пиксель с драйвером не гарантируется и не проверяется.

  Чему модуль СООТВЕТСТВУЕТ спецификации GL (и это покрыто test_raster):
    * отображение NDC в окно: x_w = (x_ndc*0.5+0.5)*W, y вниз;
    * лицевая грань -- обход против часовой при оси Y вверх (GL_CCW);
    * перспективно корректная интерполяция атрибутов через 1/w;
    * тест глубины GL_LESS по z из NDC;
    * отсечение по ближней плоскости z >= -w.

  Чем модуль заведомо ОТЛИЧАЕТСЯ от настоящего GL:
    * нет мультисэмплинга (демо просит GLFW_SAMPLES = 4);
    * нет правила "верх-лево" при заполнении: пиксели ровно на общем ребре
      двух треугольников могут быть закрашены дважды;
    * отсечение только по ближней плоскости, остальные пять заменены
      обрезкой прямоугольника в экранных координатах;
    * производные fwidth считаются конечной разностью по одному пикселю,
      а видеокарта берёт их по квадрату 2x2;
    * арифметика Single на CPU против float32 на GPU: порядок операций,
      FMA и округление отличаются, точного совпадения байтов не будет;
    * фрагментная функция здесь -- это РУЧНОЙ ПЕРЕВОД шейдера FS_LIT на
      Паскаль. Два разных исходника, и расходятся они молча. Если правите
      шейдер -- правьте и sg_shade.
  ============================================================================ }
unit usoftgl;

{$MODE OBJFPC}
{$H+}

interface

uses
  SysUtils, Math, umath, ugeom, ucamera;

type
  TPixel = record
    r, g, b: Single;
  end;

var
  sg_w, sg_h   : Integer;
  sg_color     : array of TPixel;
  sg_depth     : array of Single;
  { Мировая позиция, с которой был закрашен пиксель. Нужна тестам, чтобы
    сверить интерполяцию с аналитическим решением. }
  sg_wpos      : array of TVec3;
  sg_cam       : TCamera;

  { те же значения, что рендерер кладёт в uniform-переменные }
  sg_light_dir : TVec3;
  sg_fog_color : TVec3;
  sg_ambient   : TVec3;
  sg_fog_near  : Single = 40.0;
  sg_fog_far   : Single = 220.0;

  sg_tris      : Integer = 0;   { треугольников подано }
  sg_rastered  : Integer = 0;   { треугольников реально закрашено }
  sg_pixels    : Integer = 0;   { пикселей записано }

procedure sg_init(w, h: Integer; const sky: TVec3);
procedure sg_draw(const verts: TVertexArray; const idx: TIndexArray;
                  const model: TMat4; const col: TVec4);
procedure sg_save_bmp(const path: string);
function  sg_at(x, y: Integer): TPixel;
function  sg_depth_at(x, y: Integer): Single;

{ Перевод мировой точки в оконные координаты -- вынесено наружу,
  чтобы тест мог сверить его с формулой из спецификации. }
function  sg_to_window(const wp: TVec3; out sx, sy, sz, invw: Single): Boolean;

{ Сетка из шейдера FS_LIT. duv -- значение fwidth(uv). }
function  sg_grid(u, v, dux, dvy: Single): Single;
function  sg_shade(const wpos, wnrm: TVec3; const col: TVec4;
                   const wpos_dx, wpos_dy: TVec3): TVec3;

implementation

procedure sg_init(w, h: Integer; const sky: TVec3);
var i: Integer;
begin
  sg_w := w;
  sg_h := h;
  SetLength(sg_color, w * h);
  SetLength(sg_depth, w * h);
  SetLength(sg_wpos, w * h);
  for i := 0 to w * h - 1 do
  begin
    sg_color[i].r := sky.x;
    sg_color[i].g := sky.y;
    sg_color[i].b := sky.z;
    sg_depth[i] := 1.0e30;
  end;
  sg_tris := 0;
  sg_rastered := 0;
  sg_pixels := 0;
end;

function sg_at(x, y: Integer): TPixel;
begin
  Result := sg_color[y * sg_w + x];
end;

function sg_depth_at(x, y: Integer): Single;
begin
  Result := sg_depth[y * sg_w + x];
end;

function sg_to_window(const wp: TVec3; out sx, sy, sz, invw: Single): Boolean;
var cx, cy, cz, cw: Single;
begin
  cx := sg_cam.viewproj.m[0] * wp.x + sg_cam.viewproj.m[4] * wp.y +
        sg_cam.viewproj.m[8] * wp.z + sg_cam.viewproj.m[12];
  cy := sg_cam.viewproj.m[1] * wp.x + sg_cam.viewproj.m[5] * wp.y +
        sg_cam.viewproj.m[9] * wp.z + sg_cam.viewproj.m[13];
  cz := sg_cam.viewproj.m[2] * wp.x + sg_cam.viewproj.m[6] * wp.y +
        sg_cam.viewproj.m[10] * wp.z + sg_cam.viewproj.m[14];
  cw := sg_cam.viewproj.m[3] * wp.x + sg_cam.viewproj.m[7] * wp.y +
        sg_cam.viewproj.m[11] * wp.z + sg_cam.viewproj.m[15];
  if cw < 1.0e-6 then
  begin
    Result := False;
    sx := 0; sy := 0; sz := 0; invw := 0;
    Exit;
  end;
  invw := 1.0 / cw;
  sx := (cx * invw * 0.5 + 0.5) * sg_w;
  sy := (1.0 - (cy * invw * 0.5 + 0.5)) * sg_h;
  sz := cz * invw;
  Result := True;
end;

{ =========================================================================
  Фрагментная функция. Повторяет FS_LIT строка в строку.
  ========================================================================= }

function sg_grid(u, v, dux, dvy: Single): Single;
var
  gu, gv, l: Single;

  function fractf(x: Single): Single; inline;
  begin
    Result := x - Floor(x);
  end;

begin
  { GLSL: g = abs(fract(uv - 0.5) - 0.5) / fwidth(uv) }
  if dux < 1.0e-20 then dux := 1.0e-20;
  if dvy < 1.0e-20 then dvy := 1.0e-20;
  gu := Abs(fractf(u - 0.5) - 0.5) / dux;
  gv := Abs(fractf(v - 0.5) - 0.5) / dvy;
  l := fmin(fmin(gu, gv), 1.0);
  Result := 0.78 + (1.0 - 0.78) * l;      { mix(0.78, 1.0, l) }
end;

{ Выбор координат сетки по доминирующей оси нормали -- как в шейдере. }
procedure grid_uv(const N, p: TVec3; out u, v: Single); inline;
begin
  if Abs(N.y) > 0.5 then
  begin
    u := p.x; v := p.z;
  end
  else if Abs(N.x) > 0.5 then
  begin
    u := p.z; v := p.y;
  end
  else
  begin
    u := p.x; v := p.y;
  end;
end;

function sg_shade(const wpos, wnrm: TVec3; const col: TVec4;
                  const wpos_dx, wpos_dy: TVec3): TVec3;
var
  N, L, V, Hv, amb, base, c: TVec3;
  ndl, spec, hemi, d, fog: Single;
  cu, cv, cux, cvx, cuy, cvy, fwu, fwv, g: Single;
begin
  N := v3_norm(wnrm);
  L := v3_norm(v3_neg(sg_light_dir));
  V := v3_norm(v3_sub(sg_cam.pos, wpos));
  Hv := v3_norm(v3_add(L, V));
  ndl := fmax(v3_dot(N, L), 0.0);

  spec := 0;
  if v3_dot(N, Hv) > 0 then
    spec := Power(v3_dot(N, Hv), 48.0) * 0.25;

  hemi := N.y * 0.5 + 0.5;
  amb := v3_lerp(v3_mul(sg_ambient, 0.45), sg_ambient, hemi);

  { fwidth(uv) = |dFdx(uv)| + |dFdy(uv)| -- берём из соседних пикселей }
  grid_uv(N, wpos, cu, cv);
  grid_uv(N, wpos_dx, cux, cvx);
  grid_uv(N, wpos_dy, cuy, cvy);
  fwu := Abs(cux - cu) + Abs(cuy - cu);
  fwv := Abs(cvx - cv) + Abs(cvy - cv);
  g := sg_grid(cu, cv, fwu, fwv);

  base := v3_mul(v3(col.x, col.y, col.z), g);
  c := v3_add(v3_mula(base, v3_add(amb, v3(ndl, ndl, ndl))),
              v3(spec * ndl, spec * ndl, spec * ndl));

  d := v3_dist(sg_cam.pos, wpos);
  fog := fclamp((d - sg_fog_near) / (sg_fog_far - sg_fog_near), 0, 1);
  c := v3_lerp(c, sg_fog_color, fog);

  Result.x := Power(fmax(c.x, 0), 1.0 / 2.2);
  Result.y := Power(fmax(c.y, 0), 1.0 / 2.2);
  Result.z := Power(fmax(c.z, 0), 1.0 / 2.2);
end;

{ =========================================================================
  Растеризация
  ========================================================================= }

type
  TClipVert = record
    cx, cy, cz, cw: Single;
    wp, wn: TVec3;
  end;

  TWinVert = record
    sx, sy, sz, invw: Single;
    wp, wn: TVec3;
  end;

function edge(const ax, ay, bx, by, cx, cy: Single): Single; inline;
begin
  Result := (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
end;

procedure raster_tri(const a, b, c: TWinVert; const col: TVec4);
var
  minx, maxx, miny, maxy, x, y, idx: Integer;
  area, inv_area, z, px, py: Single;
  wp, wn, wpx, wpy, outc: TVec3;

  { Мировая позиция в произвольной точке экрана внутри этого треугольника:
    нужна и для самого пикселя, и для соседних -- оттуда берутся
    производные, то есть аналог fwidth. }
  function world_at(qx, qy: Single; out p, n: TVec3): Boolean;
  var w0, w1, w2, iw: Single;
  begin
    w0 := edge(b.sx, b.sy, c.sx, c.sy, qx, qy) * inv_area;
    w1 := edge(c.sx, c.sy, a.sx, a.sy, qx, qy) * inv_area;
    w2 := 1.0 - w0 - w1;
    iw := w0 * a.invw + w1 * b.invw + w2 * c.invw;
    if iw <= 0 then
    begin
      Result := False;
      p := v3_zero; n := v3_zero;
      Exit;
    end;
    p := v3_mul(v3_add(v3_add(v3_mul(a.wp, w0 * a.invw),
                              v3_mul(b.wp, w1 * b.invw)),
                       v3_mul(c.wp, w2 * c.invw)), 1.0 / iw);
    n := v3_mul(v3_add(v3_add(v3_mul(a.wn, w0 * a.invw),
                              v3_mul(b.wn, w1 * b.invw)),
                       v3_mul(c.wn, w2 * c.invw)), 1.0 / iw);
    Result := True;
  end;

var
  w0, w1, w2: Single;
begin
  area := edge(a.sx, a.sy, b.sx, b.sy, c.sx, c.sy);
  { В GL лицевая грань -- обход против часовой при оси Y вверх. У оконных
    координат Y направлен вниз, поэтому знак площади меняется на обратный:
    лицевые треугольники дают area < 0. }
  if area >= 0 then Exit;
  inv_area := 1.0 / area;

  minx := Trunc(fmax(fmin(fmin(a.sx, b.sx), c.sx), 0));
  maxx := Trunc(fmin(fmax(fmax(a.sx, b.sx), c.sx), sg_w - 1));
  miny := Trunc(fmax(fmin(fmin(a.sy, b.sy), c.sy), 0));
  maxy := Trunc(fmin(fmax(fmax(a.sy, b.sy), c.sy), sg_h - 1));
  if (minx > maxx) or (miny > maxy) then Exit;

  Inc(sg_rastered);
  for y := miny to maxy do
  begin
    py := y + 0.5;
    for x := minx to maxx do
    begin
      px := x + 0.5;
      w0 := edge(b.sx, b.sy, c.sx, c.sy, px, py) * inv_area;
      if w0 < 0 then Continue;
      w1 := edge(c.sx, c.sy, a.sx, a.sy, px, py) * inv_area;
      if w1 < 0 then Continue;
      w2 := 1.0 - w0 - w1;
      if w2 < 0 then Continue;

      z := w0 * a.sz + w1 * b.sz + w2 * c.sz;
      idx := y * sg_w + x;
      if z >= sg_depth[idx] then Continue;      { GL_LESS }

      if not world_at(px, py, wp, wn) then Continue;
      world_at(px + 1, py, wpx, outc);
      world_at(px, py + 1, wpy, outc);

      outc := sg_shade(wp, wn, col, wpx, wpy);
      sg_depth[idx] := z;
      sg_wpos[idx] := wp;
      sg_color[idx].r := outc.x;
      sg_color[idx].g := outc.y;
      sg_color[idx].b := outc.z;
      Inc(sg_pixels);
    end;
  end;
end;

procedure to_clip(const model: TMat4; const vtx: TVertex; out cv: TClipVert);
var wp, wn: TVec3;
begin
  wp := m4_transform_point(model, v3(vtx.px, vtx.py, vtx.pz));
  wn := m4_transform_dir(model, v3(vtx.nx, vtx.ny, vtx.nz));
  cv.cx := sg_cam.viewproj.m[0] * wp.x + sg_cam.viewproj.m[4] * wp.y +
           sg_cam.viewproj.m[8] * wp.z + sg_cam.viewproj.m[12];
  cv.cy := sg_cam.viewproj.m[1] * wp.x + sg_cam.viewproj.m[5] * wp.y +
           sg_cam.viewproj.m[9] * wp.z + sg_cam.viewproj.m[13];
  cv.cz := sg_cam.viewproj.m[2] * wp.x + sg_cam.viewproj.m[6] * wp.y +
           sg_cam.viewproj.m[10] * wp.z + sg_cam.viewproj.m[14];
  cv.cw := sg_cam.viewproj.m[3] * wp.x + sg_cam.viewproj.m[7] * wp.y +
           sg_cam.viewproj.m[11] * wp.z + sg_cam.viewproj.m[15];
  cv.wp := wp;
  cv.wn := wn;
end;

function clip_dist(const v: TClipVert): Single; inline;
begin
  Result := v.cz + v.cw;            { ближняя плоскость GL: z >= -w }
end;

procedure clip_lerp(const a, b: TClipVert; t: Single; out r: TClipVert); inline;
begin
  r.cx := a.cx + (b.cx - a.cx) * t;
  r.cy := a.cy + (b.cy - a.cy) * t;
  r.cz := a.cz + (b.cz - a.cz) * t;
  r.cw := a.cw + (b.cw - a.cw) * t;
  r.wp := v3_lerp(a.wp, b.wp, t);
  r.wn := v3_lerp(a.wn, b.wn, t);
end;

{ Отсечение по ближней плоскости, алгоритм Сазерленда-Ходжмена. }
procedure clip_near(const inp: array of TClipVert; nin: Integer;
                    out outp: array of TClipVert; out nout: Integer);
var
  i, j: Integer;
  da, db, t: Single;
begin
  nout := 0;
  for i := 0 to nin - 1 do
  begin
    j := (i + 1) mod nin;
    da := clip_dist(inp[i]);
    db := clip_dist(inp[j]);
    if da >= 0 then
    begin
      outp[nout] := inp[i];
      Inc(nout);
    end;
    if ((da >= 0) and (db < 0)) or ((da < 0) and (db >= 0)) then
    begin
      t := da / (da - db);
      clip_lerp(inp[i], inp[j], t, outp[nout]);
      Inc(nout);
    end;
  end;
end;

procedure to_window(const cv: TClipVert; out wv: TWinVert); inline;
begin
  wv.invw := 1.0 / cv.cw;
  wv.sx := (cv.cx * wv.invw * 0.5 + 0.5) * sg_w;
  wv.sy := (1.0 - (cv.cy * wv.invw * 0.5 + 0.5)) * sg_h;
  wv.sz := cv.cz * wv.invw;
  wv.wp := cv.wp;
  wv.wn := cv.wn;
end;

procedure sg_draw(const verts: TVertexArray; const idx: TIndexArray;
                  const model: TMat4; const col: TVec4);
var
  i, k, n: Integer;
  tri: array[0..2] of TClipVert;
  poly: array[0..5] of TClipVert;
  a, b, c: TWinVert;
begin
  i := 0;
  while i + 2 <= High(idx) do
  begin
    Inc(sg_tris);
    to_clip(model, verts[idx[i]], tri[0]);
    to_clip(model, verts[idx[i + 1]], tri[1]);
    to_clip(model, verts[idx[i + 2]], tri[2]);

    clip_near(tri, 3, poly, n);
    for k := 1 to n - 2 do
    begin
      to_window(poly[0], a);
      to_window(poly[k], b);
      to_window(poly[k + 1], c);
      raster_tri(a, b, c, col);
    end;
    Inc(i, 3);
  end;
end;

procedure sg_save_bmp(const path: string);
var
  f: file;
  hdr: array[0..53] of Byte;
  row: array of Byte;
  x, y, i: Integer;
  rowsize, datasize, filesize: LongWord;

  function tobyte(v: Single): Byte;
  begin
    if v <= 0 then Result := 0
    else if v >= 1 then Result := 255
    else Result := Round(v * 255);
  end;

begin
  rowsize := ((sg_w * 3 + 3) div 4) * 4;
  datasize := rowsize * sg_h;
  filesize := 54 + datasize;
  FillChar(hdr, SizeOf(hdr), 0);
  hdr[0] := Ord('B'); hdr[1] := Ord('M');
  PLongWord(@hdr[2])^ := filesize;
  PLongWord(@hdr[10])^ := 54;
  PLongWord(@hdr[14])^ := 40;
  PLongInt(@hdr[18])^ := sg_w;
  PLongInt(@hdr[22])^ := sg_h;
  PWord(@hdr[26])^ := 1;
  PWord(@hdr[28])^ := 24;
  PLongWord(@hdr[34])^ := datasize;

  SetLength(row, rowsize);
  AssignFile(f, path);
  Rewrite(f, 1);
  BlockWrite(f, hdr, 54);
  for y := sg_h - 1 downto 0 do
  begin
    FillChar(row[0], rowsize, 0);
    for x := 0 to sg_w - 1 do
    begin
      i := y * sg_w + x;
      row[x * 3 + 0] := tobyte(sg_color[i].b);
      row[x * 3 + 1] := tobyte(sg_color[i].g);
      row[x * 3 + 2] := tobyte(sg_color[i].r);
    end;
    BlockWrite(f, row[0], rowsize);
  end;
  CloseFile(f);
end;

initialization
  sg_light_dir := v3_norm(v3(-0.45, -0.8, -0.35));
  sg_fog_color := v3(0.52, 0.62, 0.74);
  sg_ambient := v3(0.30, 0.34, 0.42);

end.
