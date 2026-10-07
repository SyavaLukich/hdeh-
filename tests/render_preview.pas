{ ============================================================================
  render_preview.pas  --  предпросмотр кадра без видеокарты

  Программа строит ту же сцену, что и демо, гоняет физику и рисует кадр
  собственным программным растеризатором: та же камера (модуль ucamera),
  та же геометрия (модуль ugeom), те же матрицы экземпляров и та же модель
  освещения, что в шейдере FS_LIT.

  OpenGL и GLFW не нужны вовсе, поэтому картинку можно получить на машине
  без видеокарты и без дисплея:

      make preview        ->  build/preview.bmp

  Что это проверяет: геометрию примитивов, нормали, порядок обхода вершин,
  матрицы камеры и экземпляров, отсечение по пирамиде видимости, модель
  освещения. Чего не проверяет: сами вызовы OpenGL и работу драйвера --
  для них нужна настоящая видеокарта.
  ============================================================================ }
program render_preview;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugeom, ucamera, ugjk, uphysics;

const
  W = 1280;
  H = 720;

type
  TPixel = record
    r, g, b: Single;
  end;

var
  g_color : array of TPixel;
  g_depth : array of Single;
  g_cam   : TCamera;
  g_tris  : Integer = 0;
  g_drawn : Integer = 0;

  { геометрия }
  vb_box, vb_ball, vb_floor: TVertexArray;
  ib_box, ib_ball, ib_floor: TIndexArray;

  { визуальные свойства тел }
  g_kind  : array[0..PHYS_MAX_BODIES - 1] of Integer;
  g_col   : array[0..PHYS_MAX_BODIES - 1] of TVec4;
  g_scale : array[0..PHYS_MAX_BODIES - 1] of TVec3;

{ =========================================================================
  Кадровый буфер
  ========================================================================= }

procedure fb_init(const sky: TVec3);
var i: Integer;
begin
  SetLength(g_color, W * H);
  SetLength(g_depth, W * H);
  for i := 0 to W * H - 1 do
  begin
    g_color[i].r := sky.x;
    g_color[i].g := sky.y;
    g_color[i].b := sky.z;
    g_depth[i] := 1.0e30;
  end;
end;

procedure fb_save_bmp(const path: string);
var
  f: file;
  hdr: array[0..53] of Byte;
  row: array of Byte;
  x, y, i: Integer;
  rowsize, datasize, filesize: LongWord;
  c: Single;

  function tobyte(v: Single): Byte;
  begin
    { шейдер отдаёт уже гамма-скорректированный цвет, здесь только клампим }
    if v <= 0 then Result := 0
    else if v >= 1 then Result := 255
    else Result := Round(v * 255);
  end;

begin
  rowsize := ((W * 3 + 3) div 4) * 4;
  datasize := rowsize * H;
  filesize := 54 + datasize;
  FillChar(hdr, SizeOf(hdr), 0);
  hdr[0] := Ord('B'); hdr[1] := Ord('M');
  PLongWord(@hdr[2])^ := filesize;
  PLongWord(@hdr[10])^ := 54;
  PLongWord(@hdr[14])^ := 40;
  PLongInt(@hdr[18])^ := W;
  PLongInt(@hdr[22])^ := H;
  PWord(@hdr[26])^ := 1;
  PWord(@hdr[28])^ := 24;
  PLongWord(@hdr[34])^ := datasize;

  SetLength(row, rowsize);
  AssignFile(f, path);
  Rewrite(f, 1);
  BlockWrite(f, hdr, 54);
  { BMP хранит строки снизу вверх }
  for y := H - 1 downto 0 do
  begin
    FillChar(row[0], rowsize, 0);
    for x := 0 to W - 1 do
    begin
      i := y * W + x;
      c := g_color[i].b; row[x * 3 + 0] := tobyte(c);
      c := g_color[i].g; row[x * 3 + 1] := tobyte(c);
      c := g_color[i].r; row[x * 3 + 2] := tobyte(c);
    end;
    BlockWrite(f, row[0], rowsize);
  end;
  CloseFile(f);
end;

{ =========================================================================
  Шейдер (ровно та же математика, что в FS_LIT)
  ========================================================================= }

var
  g_light_dir: TVec3;
  g_fog_color: TVec3;
  g_ambient  : TVec3;
  g_fog_near : Single = 40.0;
  g_fog_far  : Single = 220.0;

function checker(u, v: Single): Single;
var
  fu, fv: Single;
  s: Integer;
begin
  fu := u - Floor(u);
  fv := v - Floor(v);
  s := 0;
  if fu > 0.5 then Inc(s);
  if fv > 0.5 then Inc(s);
  if (s = 1) then Result := 0.78 else Result := 1.0;
end;

function shade(const wpos, wnrm: TVec3; const col: TVec4): TVec3;
var
  N, L, V, Hv, amb, base, c: TVec3;
  ndl, spec, hemi, d, fog, cu, cv: Single;
begin
  N := v3_norm(wnrm);
  L := v3_norm(v3_neg(g_light_dir));
  V := v3_norm(v3_sub(g_cam.pos, wpos));
  Hv := v3_norm(v3_add(L, V));
  ndl := fmax(v3_dot(N, L), 0.0);
  spec := 0;
  if v3_dot(N, Hv) > 0 then
    spec := Exp(48.0 * Ln(fmax(v3_dot(N, Hv), 1.0e-6))) * 0.25;

  hemi := N.y * 0.5 + 0.5;
  amb := v3_lerp(v3_mul(g_ambient, 0.45), g_ambient, hemi);

  { координаты клетки по доминирующей оси нормали -- как в шейдере }
  if Abs(N.y) > 0.5 then
  begin
    cu := wpos.x; cv := wpos.z;
  end
  else if Abs(N.x) > 0.5 then
  begin
    cu := wpos.z; cv := wpos.y;
  end
  else
  begin
    cu := wpos.x; cv := wpos.y;
  end;

  base := v3_mul(v3(col.x, col.y, col.z), checker(cu, cv));
  c := v3_add(v3_mula(base, v3_add(amb, v3(ndl, ndl, ndl))),
              v3(spec * ndl, spec * ndl, spec * ndl));

  d := v3_dist(g_cam.pos, wpos);
  fog := fclamp((d - g_fog_near) / (g_fog_far - g_fog_near), 0, 1);
  c := v3_lerp(c, g_fog_color, fog);

  { гамма }
  Result.x := Exp(Ln(fmax(c.x, 0)) / 2.2);
  Result.y := Exp(Ln(fmax(c.y, 0)) / 2.2);
  Result.z := Exp(Ln(fmax(c.z, 0)) / 2.2);
  if c.x <= 0 then Result.x := 0;
  if c.y <= 0 then Result.y := 0;
  if c.z <= 0 then Result.z := 0;
end;

{ =========================================================================
  Растеризатор
  ========================================================================= }

type
  TRasterVert = record
    sx, sy, sz, invw: Single;    { экран + обратная глубина }
    wp, wn: TVec3;               { мировые позиция и нормаль }
  end;

procedure raster_tri(const a, b, c: TRasterVert; const col: TVec4);
var
  minx, maxx, miny, maxy, x, y, idx: Integer;
  area, w0, w1, w2, iw, z, px, py: Single;
  wp, wn, outc: TVec3;

  function edge(const ax, ay, bx, by, cx, cy: Single): Single; inline;
  begin
    Result := (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  end;

begin
  area := edge(a.sx, a.sy, b.sx, b.sy, c.sx, c.sy);
  { В OpenGL лицевая грань -- обход против часовой при оси Y вверх.
    У экранного буфера Y смотрит вниз, поэтому знак меняется. }
  if area >= 0 then Exit;

  minx := Trunc(fmax(fmin(fmin(a.sx, b.sx), c.sx), 0));
  maxx := Trunc(fmin(fmax(fmax(a.sx, b.sx), c.sx), W - 1));
  miny := Trunc(fmax(fmin(fmin(a.sy, b.sy), c.sy), 0));
  maxy := Trunc(fmin(fmax(fmax(a.sy, b.sy), c.sy), H - 1));
  if (minx > maxx) or (miny > maxy) then Exit;

  Inc(g_drawn);
  for y := miny to maxy do
  begin
    py := y + 0.5;
    for x := minx to maxx do
    begin
      px := x + 0.5;
      w0 := edge(b.sx, b.sy, c.sx, c.sy, px, py) / area;
      if w0 < 0 then Continue;
      w1 := edge(c.sx, c.sy, a.sx, a.sy, px, py) / area;
      if w1 < 0 then Continue;
      w2 := 1.0 - w0 - w1;
      if w2 < 0 then Continue;

      z := w0 * a.sz + w1 * b.sz + w2 * c.sz;
      idx := y * W + x;
      if z >= g_depth[idx] then Continue;

      { перспективно-корректная интерполяция атрибутов }
      iw := w0 * a.invw + w1 * b.invw + w2 * c.invw;
      if iw <= 0 then Continue;
      wp := v3_mul(v3_add(v3_add(v3_mul(a.wp, w0 * a.invw),
                                 v3_mul(b.wp, w1 * b.invw)),
                          v3_mul(c.wp, w2 * c.invw)), 1.0 / iw);
      wn := v3_mul(v3_add(v3_add(v3_mul(a.wn, w0 * a.invw),
                                 v3_mul(b.wn, w1 * b.invw)),
                          v3_mul(c.wn, w2 * c.invw)), 1.0 / iw);

      outc := shade(wp, wn, col);
      g_depth[idx] := z;
      g_color[idx].r := outc.x;
      g_color[idx].g := outc.y;
      g_color[idx].b := outc.z;
    end;
  end;
end;

{ Вершина в однородных координатах отсечения плюс атрибуты. }
type
  TClipVert = record
    cx, cy, cz, cw: Single;
    wp, wn: TVec3;
  end;

procedure to_clip(const model: TMat4; const vtx: TVertex; out cv: TClipVert);
var
  wp, wn: TVec3;
begin
  wp := m4_transform_point(model, v3(vtx.px, vtx.py, vtx.pz));
  wn := m4_transform_dir(model, v3(vtx.nx, vtx.ny, vtx.nz));
  cv.cx := g_cam.viewproj.m[0] * wp.x + g_cam.viewproj.m[4] * wp.y +
           g_cam.viewproj.m[8] * wp.z + g_cam.viewproj.m[12];
  cv.cy := g_cam.viewproj.m[1] * wp.x + g_cam.viewproj.m[5] * wp.y +
           g_cam.viewproj.m[9] * wp.z + g_cam.viewproj.m[13];
  cv.cz := g_cam.viewproj.m[2] * wp.x + g_cam.viewproj.m[6] * wp.y +
           g_cam.viewproj.m[10] * wp.z + g_cam.viewproj.m[14];
  cv.cw := g_cam.viewproj.m[3] * wp.x + g_cam.viewproj.m[7] * wp.y +
           g_cam.viewproj.m[11] * wp.z + g_cam.viewproj.m[15];
  cv.wp := wp;
  cv.wn := wn;
end;

function clip_dist(const v: TClipVert): Single; inline;
begin
  { ближняя плоскость OpenGL: z >= -w }
  Result := v.cz + v.cw;
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

{ Отсечение треугольника по ближней плоскости (алгоритм Сазерленда-Ходжмена).
  Без него большой пол, уходящий за спину камеры, пропадал бы целиком:
  на видеокарте это делает аппаратный клиппер, здесь приходится руками. }
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

procedure viewport(const cv: TClipVert; out rv: TRasterVert); inline;
begin
  rv.invw := 1.0 / cv.cw;
  rv.sx := (cv.cx * rv.invw * 0.5 + 0.5) * W;
  rv.sy := (1.0 - (cv.cy * rv.invw * 0.5 + 0.5)) * H;
  rv.sz := cv.cz * rv.invw;
  rv.wp := cv.wp;
  rv.wn := cv.wn;
end;

procedure draw_instance(const verts: TVertexArray; const idx: TIndexArray;
                        const model: TMat4; const col: TVec4);
var
  i, k, n: Integer;
  tri: array[0..2] of TClipVert;
  poly: array[0..5] of TClipVert;
  a, b, c: TRasterVert;
begin
  i := 0;
  while i + 2 <= High(idx) do
  begin
    Inc(g_tris);
    to_clip(model, verts[idx[i]], tri[0]);
    to_clip(model, verts[idx[i + 1]], tri[1]);
    to_clip(model, verts[idx[i + 2]], tri[2]);

    clip_near(tri, 3, poly, n);
    { после отсечения получается веер из n-2 треугольников }
    for k := 1 to n - 2 do
    begin
      viewport(poly[0], a);
      viewport(poly[k], b);
      viewport(poly[k + 1], c);
      raster_tri(a, b, c, col);
    end;
    Inc(i, 3);
  end;
end;

{ =========================================================================
  Сцена -- уменьшенная копия демонстрационной
  ========================================================================= }

function add_box(const pos, half: TVec3; mass: Single; const col: TVec4): Integer;
var
  pts: array[0..7] of TVec3;
  id: Integer;
begin
  box_hull_points(half, pts);
  id := phys_add_body(shape_hull(pts), pos,
                      q_from_euler(0, rand_range(-0.25, 0.25), 0), mass);
  phys_set_material(id, 0.55, 0.05);
  g_kind[id] := 0;
  g_col[id] := col;
  g_scale[id] := half;
  Result := id;
end;

function add_ball(const pos: TVec3; r, mass: Single; const col: TVec4): Integer;
var id: Integer;
begin
  id := phys_add_body(shape_sphere(r), pos, q_identity, mass);
  phys_set_material(id, 0.4, 0.3);
  g_kind[id] := 1;
  g_col[id] := col;
  g_scale[id] := v3(r, r, r);
  Result := id;
end;

procedure build_scene;
var
  i, j, k, layers, id: Integer;
  half, p: TVec3;
  col: TVec4;
  pts: array[0..7] of TVec3;
begin
  phys_init;

  half := v3(60, 1, 60);
  box_hull_points(half, pts);
  id := phys_add_body(shape_hull(pts), v3(0, -1, 0), q_identity, 0.0);
  phys_set_material(id, 0.8, 0.0);
  g_kind[id] := 2;
  g_col[id] := v4_make(0.42, 0.46, 0.40, 1);
  g_scale[id] := half;

  layers := 7;
  for k := 0 to layers - 1 do
    for i := 0 to layers - 1 - k do
      for j := 0 to layers - 1 - k do
      begin
        p := v3(-(layers - k) * 0.55 + i * 1.1,
                0.55 + k * 1.1,
                -(layers - k) * 0.55 + j * 1.1);
        col := v4_make(0.35 + 0.05 * k, 0.55 - 0.02 * k, 0.75 - 0.03 * k, 1);
        add_box(p, v3(0.5, 0.5, 0.5), 1.0, col);
      end;

  for i := 0 to 7 do
    add_ball(v3(rand_range(-5, 5), 9 + i * 1.6, rand_range(-5, 5)),
             rand_range(0.4, 0.8), 4.0, v4_make(0.9, 0.55, 0.25, 1));

  for k := 0 to 5 do
    for i := 0 to 7 do
      add_box(v3(12 + (k mod 2) * 0.2, 0.4 + k * 0.8, -4 + i * 1.3),
              v3(0.6, 0.4, 0.6), 1.5, v4_make(0.75, 0.72, 0.62, 1));
end;

{ =========================================================================
  Главная программа
  ========================================================================= }

var
  i, steps, culled: Integer;
  m: TMat4;
  t0: TDateTime;
  box: TAABB;
begin
  g_light_dir := v3_norm(v3(-0.45, -0.8, -0.35));
  g_fog_color := v3(0.52, 0.62, 0.74);
  g_ambient := v3(0.30, 0.34, 0.42);

  geom_box(v3(1, 1, 1), vb_box, ib_box);
  geom_sphere(1.0, 24, 16, vb_ball, ib_ball);
  geom_box(v3(1, 1, 1), vb_floor, ib_floor);

  WriteLn(Format('геометрия: ящик %d верш./%d инд., шар %d/%d',
          [Length(vb_box), Length(ib_box), Length(vb_ball), Length(ib_ball)]));

  build_scene;
  steps := 300;                      { 2.5 секунды физики }
  for i := 1 to steps do phys_step(1.0 / 120.0);
  WriteLn(Format('физика: %d тел, %d шагов, не спят: %d',
          [g_nbodies, steps, g_stat_awake]));

  camera_init(g_cam, v3(13, 9, 21));
  g_cam.yaw := -2.25;
  g_cam.pitch := -0.33;
  camera_update(g_cam, W, H);

  fb_init(g_fog_color);

  t0 := Now;
  culled := 0;
  for i := 0 to g_nbodies - 1 do
  begin
    box := aabb_expand(g_bodies[i].box, 0.5);
    if not frustum_test_aabb(g_cam.frustum, box) then
    begin
      Inc(culled);
      Continue;
    end;
    m := m4_compose(g_bodies[i].pos, g_bodies[i].orient, g_scale[i]);
    case g_kind[i] of
      0: draw_instance(vb_box, ib_box, m, g_col[i]);
      1: draw_instance(vb_ball, ib_ball, m, g_col[i]);
      2: draw_instance(vb_floor, ib_floor, m, g_col[i]);
    end;
  end;

  WriteLn(Format('кадр: %dx%d, отсечено по пирамиде: %d тел, треугольников: %d, видимых: %d, %.0f мс',
          [W, H, culled, g_tris, g_drawn, (Now - t0) * 24 * 60 * 60 * 1000]));

  fb_save_bmp('build/preview.bmp');
  WriteLn('сохранено: build/preview.bmp');
end.
