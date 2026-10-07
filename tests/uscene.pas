{ ============================================================================
  uscene.pas  --  общая демонстрационная сцена для проверок

  Один и тот же мир строят и программный растеризатор (render_preview), и
  безэкранный прогон через настоящий OpenGL (render_gl). Сцена обязана быть
  побитово одинаковой, иначе два кадра не с чем сравнивать, поэтому она
  вынесена сюда, а генератор случайных чисел не перемешивается.

  Модуль ничего не знает про OpenGL.
  ============================================================================ }
unit uscene;

{$MODE OBJFPC}
{$H+}

interface

uses
  SysUtils, umath, ugeom, ugjk, uphysics;

const
  SC_BOX   = 0;
  SC_BALL  = 1;
  SC_FLOOR = 2;

var
  { визуальные свойства тел, индекс совпадает с индексом тела в физике }
  g_kind  : array[0..PHYS_MAX_BODIES - 1] of Integer;
  g_col   : array[0..PHYS_MAX_BODIES - 1] of TVec4;
  g_scale : array[0..PHYS_MAX_BODIES - 1] of TVec3;

procedure build_scene;
procedure scene_settle(steps: Integer);

implementation

function add_box(const pos, half: TVec3; mass: Single; const col: TVec4): Integer;
var
  pts: array[0..7] of TVec3;
  id: Integer;
begin
  box_hull_points(half, pts);
  id := phys_add_body(shape_hull(pts), pos,
                      q_from_euler(0, rand_range(-0.25, 0.25), 0), mass);
  phys_set_material(id, 0.55, 0.05);
  g_kind[id] := SC_BOX;
  g_col[id] := col;
  g_scale[id] := half;
  Result := id;
end;

function add_ball(const pos: TVec3; r, mass: Single; const col: TVec4): Integer;
var id: Integer;
begin
  id := phys_add_body(shape_sphere(r), pos, q_identity, mass);
  phys_set_material(id, 0.4, 0.3);
  g_kind[id] := SC_BALL;
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
  g_kind[id] := SC_FLOOR;
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


procedure scene_settle(steps: Integer);
var i: Integer;
begin
  for i := 1 to steps do phys_step(1.0 / 120.0);
end;

end.
