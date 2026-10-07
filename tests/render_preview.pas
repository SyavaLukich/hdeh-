{ ============================================================================
  render_preview.pas  --  предпросмотр кадра без видеокарты

  Строит ту же сцену, что и демо, гоняет физику и рисует кадр модулем
  usoftgl. Границы доверия к картинке честно перечислены в заголовке
  usoftgl.pas: это независимая реализация конвейера по спецификации GL,
  а не эталон и не доказательство корректности драйверного пути.

      make preview        ->  build/preview.png
  ============================================================================ }
program render_preview;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugeom, ucamera, ugjk, uphysics, usoftgl;

const
  W = 1280;
  H = 720;

var
  { геометрия }
  vb_box, vb_ball, vb_floor: TVertexArray;
  ib_box, ib_ball, ib_floor: TIndexArray;

  { визуальные свойства тел }
  g_kind  : array[0..PHYS_MAX_BODIES - 1] of Integer;
  g_col   : array[0..PHYS_MAX_BODIES - 1] of TVec4;
  g_scale : array[0..PHYS_MAX_BODIES - 1] of TVec3;

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

  camera_init(sg_cam, v3(13, 9, 21));
  sg_cam.yaw := -2.25;
  sg_cam.pitch := -0.33;
  camera_update(sg_cam, W, H);

  sg_init(W, H, sg_fog_color);

  t0 := Now;
  culled := 0;
  for i := 0 to g_nbodies - 1 do
  begin
    box := aabb_expand(g_bodies[i].box, 0.5);
    if not frustum_test_aabb(sg_cam.frustum, box) then
    begin
      Inc(culled);
      Continue;
    end;
    m := m4_compose(g_bodies[i].pos, g_bodies[i].orient, g_scale[i]);
    case g_kind[i] of
      0: sg_draw(vb_box, ib_box, m, g_col[i]);
      1: sg_draw(vb_ball, ib_ball, m, g_col[i]);
      2: sg_draw(vb_floor, ib_floor, m, g_col[i]);
    end;
  end;

  WriteLn(Format('кадр: %dx%d, отсечено: %d тел, треугольников: %d, закрашено: %d, пикселей: %d, %.0f мс',
          [W, H, culled, sg_tris, sg_rastered, sg_pixels,
           (Now - t0) * 24 * 60 * 60 * 1000]));

  sg_save_bmp('build/preview.bmp');
  WriteLn('сохранено: build/preview.bmp');
end.
