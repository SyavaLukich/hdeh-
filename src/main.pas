{ ============================================================================
  main.pas  --  демонстрационная программа движка

  Собирает всё вместе: окно GLFW, контекст OpenGL 3.3 Core, рендерер,
  физика на GJK/EPA.

  Управление:
    W A S D          -- движение
    Space / Ctrl     -- вверх / вниз
    Shift            -- ускорение
    мышь             -- обзор
    ЛКМ              -- выстрелить шаром
    ПКМ              -- выстрелить ящиком
    R                -- перестроить сцену
    F1               -- отладочная отрисовка (AABB, контакты)
    F2               -- вкл/выкл паузу физики
    F3               -- один шаг физики (в паузе)
    Esc              -- выход
  ============================================================================ }
program main;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, umath, uglfw, ugl, umesh, urender, ugjk, uphysics;

const
  WIN_W = 1280;
  WIN_H = 720;
  FIXED_DT = 1.0 / 120.0;     { физика живёт на своей частоте }
  MAX_SUBSTEPS = 8;
  MAX_INSTANCES = 4096;

type
  { Визуальное представление физического тела. Параллельный массив,
    а не поле внутри TBody: физике не нужно знать про графику. }
  TVisual = record
    kind   : Integer;       { 0 -- ящик, 1 -- шар, 2 -- пол }
    color  : TVec4;
    scale  : TVec3;
    prevPos: TVec3;         { для интерполяции между шагами физики }
    prevRot: TQuat;
  end;

var
  g_win       : PGLFWwindow;
  g_cam       : TCamera;
  g_mesh_box  : TMesh;
  g_mesh_ball : TMesh;
  g_mesh_floor: TMesh;

  g_vis       : array[0..PHYS_MAX_BODIES - 1] of TVisual;

  g_inst_box  : array[0..MAX_INSTANCES - 1] of TInstance;
  g_inst_ball : array[0..MAX_INSTANCES - 1] of TInstance;
  g_inst_floor: array[0..7] of TInstance;

  g_prevLMB   : Boolean = False;
  g_prevRMB   : Boolean = False;
  g_debug_draw: Boolean = False;
  g_paused    : Boolean = False;
  g_stepOnce  : Boolean = False;

  g_lastMX, g_lastMY: Double;
  g_firstMouse: Boolean = True;
  g_accum     : Double = 0;

  g_fb_w: Integer = WIN_W;
  g_fb_h: Integer = WIN_H;

{ ===========================================================================
  Обратные вызовы GLFW
  =========================================================================== }

procedure on_error(code: Integer; const desc: PChar); cdecl;
begin
  WriteLn('[glfw] ошибка ', code, ': ', desc);
end;

procedure on_resize(wnd: PGLFWwindow; w, h: Integer); cdecl;
begin
  if w < 1 then w := 1;
  if h < 1 then h := 1;
  g_fb_w := w;
  g_fb_h := h;
  glViewport(0, 0, w, h);
end;

procedure on_mouse(wnd: PGLFWwindow; x, y: Double); cdecl;
const
  SENS = 0.0022;
begin
  if g_firstMouse then
  begin
    g_lastMX := x;
    g_lastMY := y;
    g_firstMouse := False;
    Exit;
  end;
  g_cam.yaw := g_cam.yaw + (x - g_lastMX) * SENS;
  g_cam.pitch := g_cam.pitch - (y - g_lastMY) * SENS;
  g_lastMX := x;
  g_lastMY := y;
end;

{ ===========================================================================
  Сцена
  =========================================================================== }

function add_box(const pos: TVec3; const half: TVec3; mass: Single;
                 const col: TVec4): Integer;
var
  pts: array[0..7] of TVec3;
  s: TShape;
  id: Integer;
begin
  box_hull_points(half, pts);
  { Ящик как выпуклая оболочка из восьми точек -- так его обрабатывает
    тот же код GJK, что и любую другую форму. }
  s := shape_hull(pts);
  id := phys_add_body(s, pos, q_from_euler(rand_range(-0.1, 0.1),
                                           rand_range(-PI_F, PI_F), 0), mass);
  if id < 0 then
  begin
    Result := -1;
    Exit;
  end;
  phys_set_material(id, 0.55, 0.05);
  g_vis[id].kind := 0;
  g_vis[id].color := col;
  g_vis[id].scale := half;
  g_vis[id].prevPos := pos;
  g_vis[id].prevRot := g_bodies[id].orient;
  Result := id;
end;

function add_ball(const pos: TVec3; r, mass: Single; const col: TVec4): Integer;
var
  id: Integer;
begin
  id := phys_add_body(shape_sphere(r), pos, q_identity, mass);
  if id < 0 then
  begin
    Result := -1;
    Exit;
  end;
  phys_set_material(id, 0.4, 0.35);
  g_vis[id].kind := 1;
  g_vis[id].color := col;
  g_vis[id].scale := v3(r, r, r);
  g_vis[id].prevPos := pos;
  g_vis[id].prevRot := q_identity;
  Result := id;
end;

procedure build_scene;
var
  i, j, k, layers, id: Integer;
  half: TVec3;
  p: TVec3;
  col: TVec4;
  pts: array[0..7] of TVec3;
begin
  phys_clear;

  { --- пол: огромный статический ящик --- }
  half := v3(60, 1, 60);
  box_hull_points(half, pts);
  id := phys_add_body(shape_hull(pts), v3(0, -1, 0), q_identity, 0.0);
  phys_set_material(id, 0.8, 0.0);
  g_vis[id].kind := 2;
  g_vis[id].color.x := 0.42;
  g_vis[id].color.y := 0.46;
  g_vis[id].color.z := 0.40;
  g_vis[id].color.w := 1.0;
  g_vis[id].scale := half;
  g_vis[id].prevPos := v3(0, -1, 0);
  g_vis[id].prevRot := q_identity;

  { --- пирамида из ящиков --- }
  layers := 10;
  for k := 0 to layers - 1 do
    for i := 0 to layers - 1 - k do
      for j := 0 to layers - 1 - k do
      begin
        p := v3(-(layers - k) * 0.55 + i * 1.1,
                0.55 + k * 1.1,
                -(layers - k) * 0.55 + j * 1.1);
        col.x := 0.35 + 0.05 * k;
        col.y := 0.55 - 0.02 * k;
        col.z := 0.75 - 0.03 * k;
        col.w := 1;
        add_box(p, v3(0.5, 0.5, 0.5), 1.0, col);
      end;

  { --- несколько тяжёлых шаров сверху --- }
  for i := 0 to 11 do
  begin
    col.x := 0.9; col.y := 0.55; col.z := 0.25; col.w := 1;
    add_ball(v3(rand_range(-6, 6), 14 + i * 1.8, rand_range(-6, 6)),
             rand_range(0.4, 0.9), 4.0, col);
  end;

  { --- стенка сбоку, чтобы было что ронять --- }
  for k := 0 to 7 do
    for i := 0 to 9 do
    begin
      col.x := 0.75; col.y := 0.72; col.z := 0.62; col.w := 1;
      add_box(v3(14 + (k mod 2) * 0.2, 0.4 + k * 0.8, -5 + i * 1.3),
              v3(0.6, 0.4, 0.6), 1.5, col);
    end;

  WriteLn('[сцена] тел: ', g_nbodies);
end;

{ ===========================================================================
  Ввод
  =========================================================================== }

procedure handle_input(dt: Single);
var
  d: TVec3;
  speed: Single;
  mouseNow, mouseNowR: Boolean;
  dir: TVec3;
  id: Integer;
  col: TVec4;
begin
  if glfwGetKey(g_win, GLFW_KEY_ESCAPE) = GLFW_PRESS then
    glfwSetWindowShouldClose(g_win, GLFW_TRUE);

  speed := 12.0;
  if glfwGetKey(g_win, GLFW_KEY_LEFT_SHIFT) = GLFW_PRESS then speed := 38.0;

  d := v3_zero;
  if glfwGetKey(g_win, GLFW_KEY_W) = GLFW_PRESS then d.z := d.z + 1;
  if glfwGetKey(g_win, GLFW_KEY_S) = GLFW_PRESS then d.z := d.z - 1;
  if glfwGetKey(g_win, GLFW_KEY_D) = GLFW_PRESS then d.x := d.x + 1;
  if glfwGetKey(g_win, GLFW_KEY_A) = GLFW_PRESS then d.x := d.x - 1;
  if glfwGetKey(g_win, GLFW_KEY_SPACE) = GLFW_PRESS then d.y := d.y + 1;
  if glfwGetKey(g_win, GLFW_KEY_LEFT_CONTROL) = GLFW_PRESS then d.y := d.y - 1;

  if not v3_iszero(d) then
    camera_move(g_cam, v3_mul(v3_norm(d), speed * dt));

  { Выстрелы. Простая защита от автоповтора: запоминаем прошлое состояние. }
  mouseNow := glfwGetMouseButton(g_win, GLFW_MOUSE_BUTTON_LEFT) = GLFW_PRESS;
  mouseNowR := glfwGetMouseButton(g_win, GLFW_MOUSE_BUTTON_RIGHT) = GLFW_PRESS;
  dir := g_cam.forward_;

  if mouseNow and not g_prevLMB then
  begin
    col.x := 0.95; col.y := 0.25; col.z := 0.2; col.w := 1;
    id := add_ball(v3_mad(g_cam.pos, dir, 1.5), 0.45, 8.0, col);
    if id >= 0 then
      phys_apply_impulse(id, v3_mul(dir, 220.0), g_bodies[id].pos);
  end;

  if mouseNowR and not g_prevRMB then
  begin
    col.x := 0.25; col.y := 0.85; col.z := 0.45; col.w := 1;
    id := add_box(v3_mad(g_cam.pos, dir, 1.8), v3(0.5, 0.5, 0.5), 5.0, col);
    if id >= 0 then
      phys_apply_impulse(id, v3_mul(dir, 160.0), g_bodies[id].pos);
  end;

  g_prevLMB := mouseNow;
  g_prevRMB := mouseNowR;
end;

procedure on_key(wnd: PGLFWwindow; key, scancode, action, mods: Integer); cdecl;
begin
  if action <> GLFW_PRESS then Exit;
  case key of
    GLFW_KEY_F1: g_debug_draw := not g_debug_draw;
    GLFW_KEY_F2: g_paused := not g_paused;
    GLFW_KEY_F3: g_stepOnce := True;
    GLFW_KEY_R:  build_scene;
  end;
end;

{ ===========================================================================
  Отрисовка кадра
  =========================================================================== }

procedure collect_and_draw(alpha: Single);
var
  i, nb, ns, nf: Integer;
  b: PBody;
  pos: TVec3;
  rot: TQuat;
  m: TMat4;
  box: TAABB;
begin
  nb := 0; ns := 0; nf := 0;

  for i := 0 to g_nbodies - 1 do
  begin
    b := @g_bodies[i];

    { Интерполяция между последним и предыдущим шагом физики: картинка
      остаётся плавной при любой частоте монитора. }
    pos := v3_lerp(g_vis[i].prevPos, b^.pos, alpha);
    rot := q_slerp(g_vis[i].prevRot, b^.orient, alpha);

    { Отсечение по пирамиде видимости до заполнения буфера экземпляров. }
    box := aabb_expand(b^.box, 0.5);
    if not frustum_test_aabb(g_cam.frustum, box) then Continue;

    m := m4_compose(pos, rot, g_vis[i].scale);

    case g_vis[i].kind of
      0: if nb < MAX_INSTANCES then
         begin
           g_inst_box[nb].model := m;
           g_inst_box[nb].color := g_vis[i].color;
           { Спящие тела чуть темнее -- наглядно видно работу усыпления. }
           if BF_SLEEPING in b^.flags then
           begin
             g_inst_box[nb].color.x := g_inst_box[nb].color.x * 0.65;
             g_inst_box[nb].color.y := g_inst_box[nb].color.y * 0.65;
             g_inst_box[nb].color.z := g_inst_box[nb].color.z * 0.70;
           end;
           Inc(nb);
         end;
      1: if ns < MAX_INSTANCES then
         begin
           g_inst_ball[ns].model := m;
           g_inst_ball[ns].color := g_vis[i].color;
           Inc(ns);
         end;
      2: if nf < 8 then
         begin
           g_inst_floor[nf].model := m;
           g_inst_floor[nf].color := g_vis[i].color;
           Inc(nf);
         end;
    end;
  end;

  render_lit_begin(g_cam);
  render_draw_batch(g_mesh_floor, g_inst_floor, nf);
  render_draw_batch(g_mesh_box, g_inst_box, nb);
  render_draw_batch(g_mesh_ball, g_inst_ball, ns);
end;

procedure draw_debug;
var
  i, k: Integer;
  mf: PManifold;
  pa: TVec3;
begin
  dbg_clear;
  for i := 0 to g_nbodies - 1 do
    if BF_SLEEPING in g_bodies[i].flags then
      dbg_aabb(g_bodies[i].box, v3(0.3, 0.3, 0.35))
    else
      dbg_aabb(g_bodies[i].box, v3(0.2, 0.9, 0.3));

  for i := 0 to g_nmanifolds - 1 do
  begin
    mf := @g_manifolds[i];
    for k := 0 to mf^.npoints - 1 do
    begin
      pa := v3_add(g_bodies[mf^.a].pos,
                   q_rotate(g_bodies[mf^.a].orient, mf^.pt[k].localA));
      dbg_cross(pa, 0.08, v3(1, 0.9, 0.1));
      dbg_line(pa, v3_mad(pa, mf^.normal, 0.4), v3(1, 0.2, 0.1));
    end;
  end;
  dbg_flush(g_cam);
end;

{ ===========================================================================
  Точка входа
  =========================================================================== }

procedure save_prev_state;
var i: Integer;
begin
  for i := 0 to g_nbodies - 1 do
  begin
    g_vis[i].prevPos := g_bodies[i].pos;
    g_vis[i].prevRot := g_bodies[i].orient;
  end;
end;

var
  tPrev, tNow, tTitle: Double;
  dt: Double;
  frames, steps: Integer;
  alpha: Single;
  physMs: Double;
  t0: Double;
begin
  glfwSetErrorCallback(@on_error);

  if glfwInit() = 0 then
  begin
    WriteLn('не удалось инициализировать GLFW');
    Halt(1);
  end;

  { Просим именно 3.3 Core: это та версия, которую гарантированно тянет
    любое железо начиная примерно с 2010 года. }
  glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
  glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
  glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
{$IFDEF DARWIN}
  glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GLFW_TRUE);
{$ENDIF}
  glfwWindowHint(GLFW_SAMPLES, 4);
  glfwWindowHint(GLFW_DEPTH_BITS, 24);

  g_win := glfwCreateWindow(WIN_W, WIN_H, 'FPC 3D Engine -- GJK physics',
                            nil, nil);
  if g_win = nil then
  begin
    WriteLn('не удалось создать окно');
    glfwTerminate;
    Halt(1);
  end;

  glfwMakeContextCurrent(g_win);
  glfwSwapInterval(1);
  glfwSetInputMode(g_win, GLFW_CURSOR, GLFW_CURSOR_DISABLED);
  if glfwRawMouseMotionSupported() <> 0 then
    glfwSetInputMode(g_win, GLFW_RAW_MOUSE_MOTION, GLFW_TRUE);

  glfwSetFramebufferSizeCallback(g_win, @on_resize);
  glfwSetCursorPosCallback(g_win, @on_mouse);
  glfwSetKeyCallback(g_win, @on_key);

  if not gl_load then
  begin
    WriteLn('драйвер не предоставил нужные функции OpenGL 3.3');
    Halt(1);
  end;

  WriteLn('GL_VENDOR   : ', glGetString(GL_VENDOR));
  WriteLn('GL_RENDERER : ', glGetString(GL_RENDERER));
  WriteLn('GL_VERSION  : ', glGetString(GL_VERSION));

  glEnable(GL_MULTISAMPLE);

  if not render_init then
  begin
    WriteLn('не удалось собрать шейдеры');
    Halt(1);
  end;

  g_mesh_box := mesh_make_box(v3(1, 1, 1));
  mesh_enable_instancing(g_mesh_box, MAX_INSTANCES);
  g_mesh_ball := mesh_make_sphere(1.0, 24, 16);
  mesh_enable_instancing(g_mesh_ball, MAX_INSTANCES);
  g_mesh_floor := mesh_make_box(v3(1, 1, 1));
  mesh_enable_instancing(g_mesh_floor, 8);

  phys_init;
  camera_init(g_cam, v3(0, 8, 26));
  build_scene;

  tPrev := glfwGetTime();
  tTitle := tPrev;
  frames := 0;
  physMs := 0;

  while glfwWindowShouldClose(g_win) = 0 do
  begin
    glfwPollEvents;

    tNow := glfwGetTime();
    dt := tNow - tPrev;
    tPrev := tNow;
    if dt > 0.25 then dt := 0.25;    { защита от "спирали смерти" }

    handle_input(dt);

    { --- фиксированный шаг физики --- }
    steps := 0;
    if g_paused then
    begin
      if g_stepOnce then
      begin
        save_prev_state;
        t0 := glfwGetTime();
        phys_step(FIXED_DT);
        physMs := (glfwGetTime() - t0) * 1000.0;
        g_stepOnce := False;
      end;
      alpha := 1.0;
    end
    else
    begin
      g_accum := g_accum + dt;
      t0 := glfwGetTime();
      while (g_accum >= FIXED_DT) and (steps < MAX_SUBSTEPS) do
      begin
        save_prev_state;
        phys_step(FIXED_DT);
        g_accum := g_accum - FIXED_DT;
        Inc(steps);
      end;
      if steps > 0 then physMs := (glfwGetTime() - t0) * 1000.0;
      if g_accum > FIXED_DT * MAX_SUBSTEPS then g_accum := 0;
      alpha := g_accum / FIXED_DT;
    end;

    { --- кадр --- }
    camera_update(g_cam, g_fb_w, g_fb_h);
    render_begin(g_cam);
    collect_and_draw(alpha);
    if g_debug_draw then draw_debug;

    glfwSwapBuffers(g_win);
    Inc(frames);

    { Статистику выводим в заголовок окна раз в полсекунды. }
    if tNow - tTitle > 0.5 then
    begin
      glfwSetWindowTitle(g_win, PChar(Format(
        'FPC 3D Engine | %d fps | тел: %d (не спят: %d) | пар: %d | контактов: %d | физика: %.2f мс',
        [Round(frames / (tNow - tTitle)), g_nbodies, g_stat_awake,
         g_stat_pairs, g_stat_contacts, physMs])));
      frames := 0;
      tTitle := tNow;
    end;
  end;

  render_shutdown;
  mesh_free(g_mesh_box);
  mesh_free(g_mesh_ball);
  mesh_free(g_mesh_floor);
  glfwDestroyWindow(g_win);
  glfwTerminate;
end.
