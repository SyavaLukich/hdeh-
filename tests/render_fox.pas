{ ============================================================================
  render_fox.pas  --  кадр через отложенный конвейер ufox

  Сцена подобрана так, чтобы было видно работу каждого прохода:
  низкое солнце даёт длинные тени, ряд шаров показывает шкалу
  шероховатости и металличности, ящики и персонажи -- контактное
  затенение, а яркое небо над горизонтом -- свечение.

      make render-fox   ->  build/fox.png
  ============================================================================ }
program render_fox;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugl, ugeom, ucamera, umesh, ugjk, uphysics,
  uskel, uragdoll, ubehave, ufox, uegl;

const
  W = 1280;
  H = 720;
  MAXI = 256;

type
  TBatch = record
    mesh : TMesh;
    inst : array[0..MAXI - 1] of TInstance;
    n    : Integer;
  end;

var
  b_floor, b_box, b_ball, b_wall, b_wet: TBatch;
  b_part: array[0..RD_MAX_PARTS - 1] of TBatch;
  nparts: Integer;
  cam: TCamera;
  fbo, rbc, rbd: GLuint;
  pixels: array of Byte;

  sk: TSkeleton;
  idle, animp, outp: TSkelPose;
  rd: array[0..2] of TRagdoll;
  st: array[0..2] of TBehaveState;
  prm: array[0..2] of TBehaveParams;
  groundY: Single;

procedure batch_add(var b: TBatch; const m: TMat4; const col, mat: TVec4);
begin
  if b.n >= MAXI then Exit;
  b.inst[b.n].model := m;
  b.inst[b.n].color := col;
  b.inst[b.n].material := mat;
  Inc(b.n);
end;

function mat4_of(const p: TVec3; const q: TQuat): TMat4;
begin
  Result := m4_compose(p, q, v3(1, 1, 1));
end;

{ ------------------------------------------------------------- сцена ---- }
var
  floorBody: Integer;

procedure build_world;
var
  pts: array[0..7] of TVec3;
  i, c: Integer;
  root: TTransform;
  p: TVec3;
begin
  phys_init;
  pts[0] := v3(-60, -1, -60); pts[1] := v3(60, -1, -60);
  pts[2] := v3(-60,  1, -60); pts[3] := v3(60,  1, -60);
  pts[4] := v3(-60, -1,  60); pts[5] := v3(60, -1,  60);
  pts[6] := v3(-60,  1,  60); pts[7] := v3(60,  1,  60);
  floorBody := phys_add_body(shape_hull(pts), v3(0, -1, 0), q_identity, 0);
  phys_set_material(floorBody, 0.95, 0.0);

  { контейнеры }
  for i := 0 to 5 do
  begin
    p := v3(-5.5 + i * 2.2, 0.75, -4.5 - (i mod 2) * 1.4);
    box_hull_points(v3(1.05, 0.75, 0.75), pts);
    c := phys_add_body(shape_hull(pts), p,
                       q_from_axis(v3(0, 1, 0), 0.12 * i), 0);
    phys_set_material(c, 0.8, 0.0);
  end;

  { рэгдолы }
  ragdoll_humanoid_skeleton(sk, 1.75);
  ragdoll_idle_pose(sk, idle);
  pose_copy(idle, animp);

  root.pos := v3_zero; root.rot := q_identity;
  ragdoll_build(rd[0], sk, idle, root, 70);
  groundY := 1.0e9;
  for i := 0 to rd[0].nparts - 1 do
    groundY := fmin(groundY, g_bodies[rd[0].part[i].body].box.mn.y);
  groundY := -groundY;

  { пересоздаём мир уже с правильной высотой }
  phys_init;
  floorBody := phys_add_body(shape_hull(pts), v3(0, -1, 0), q_identity, 0);
  pts[0] := v3(-60, -1, -60); pts[1] := v3(60, -1, -60);
  pts[2] := v3(-60,  1, -60); pts[3] := v3(60,  1, -60);
  pts[4] := v3(-60, -1,  60); pts[5] := v3(60, -1,  60);
  pts[6] := v3(-60,  1,  60); pts[7] := v3(60,  1,  60);
  phys_init;
  floorBody := phys_add_body(shape_hull(pts), v3(0, -1, 0), q_identity, 0);
  phys_set_material(floorBody, 0.95, 0.0);
  for i := 0 to 5 do
  begin
    box_hull_points(v3(1.05, 0.75, 0.75), pts);
    c := phys_add_body(shape_hull(pts),
                       v3(-5.5 + i * 2.2, 0.75, -4.5 - (i mod 2) * 1.4),
                       q_from_axis(v3(0, 1, 0), 0.12 * i), 0);
    phys_set_material(c, 0.8, 0.0);
  end;

  for c := 0 to 2 do
  begin
    root.pos := v3(-1.8 + c * 1.9, groundY, 0.6);
    root.rot := q_from_axis(v3(0, 1, 0), -0.4 + c * 0.35);
    ragdoll_build(rd[c], sk, idle, root, 70);
    behave_defaults(prm[c]);
    behave_init(st[c]);
  end;
  prm[0].flags := [BH_TONE, BH_BALANCE, BH_STEP];
  prm[1].flags := [BH_TONE, BH_BALANCE, BH_STEP, BH_PROTECT, BH_TUCK];
  prm[2].flags := [];
  nparts := rd[0].nparts;
end;

procedure make_meshes;
var i: Integer;
begin
  b_floor.mesh := mesh_make_box(v3(60, 1, 60));
  mesh_enable_instancing(b_floor.mesh, 1);
  b_box.mesh := mesh_make_box(v3(1.05, 0.75, 0.75));
  mesh_enable_instancing(b_box.mesh, 16);
  b_ball.mesh := mesh_make_sphere(0.45, 28, 20);
  mesh_enable_instancing(b_ball.mesh, 16);
  b_wall.mesh := mesh_make_box(v3(0.4, 1.6, 6.0));
  mesh_enable_instancing(b_wall.mesh, 4);
  { мокрая полированная площадка -- на ней видно отражения }
  b_wet.mesh := mesh_make_box(v3(5.0, 0.03, 2.8));
  mesh_enable_instancing(b_wet.mesh, 2);
  for i := 0 to nparts - 1 do
  begin
    if rd[0].part[i].isFoot then
      b_part[i].mesh := mesh_make_box(v3(rd[0].part[i].halfW,
                                         rd[0].part[i].halfLen,
                                         rd[0].part[i].halfH))
    else
      b_part[i].mesh := mesh_make_capsule(rd[0].part[i].radius,
                                          rd[0].part[i].halfLen, 14, 10);
    mesh_enable_instancing(b_part[i].mesh, 4);
  end;
end;

procedure fill_batches;
var
  i, c, b: Integer;
  col: TVec4;
begin
  b_floor.n := 0; b_box.n := 0; b_ball.n := 0; b_wall.n := 0; b_wet.n := 0;
  for i := 0 to nparts - 1 do b_part[i].n := 0;

  { пол: песок, шероховатый диэлектрик, заметная зависимость от угла }
  batch_add(b_floor, mat4_of(v3(0, -1, 0), q_identity),
            v4_make(0.46, 0.40, 0.30, 1), v4_make(0.86, 0.0, 0.35, 0.9));

  { Мокрый асфальт: гладкий диэлектрик с сильным отражением.
    Именно такие поверхности в Ground Zeroes показывали работу SSR. }
  batch_add(b_wet, mat4_of(v3(0.5, -0.018, 4.4), q_identity),
            v4_make(0.055, 0.060, 0.065, 1), v4_make(0.06, 0.0, 1.0, 1.0));

  { контейнеры: крашеный металл }
  for i := 0 to 5 do
    batch_add(b_box, mat4_of(v3(-5.5 + i * 2.2, 0.75,
                                -4.5 - (i mod 2) * 1.4),
                             q_from_axis(v3(0, 1, 0), 0.12 * i)),
              v4_make(0.26 + 0.05 * (i mod 3), 0.31, 0.27, 1),
              v4_make(0.30 + 0.09 * i, 0.75, 0.5, 0.6));

  { стена-укрытие: бетон }
  batch_add(b_wall, mat4_of(v3(6.4, 0.6, -1.0),
                            q_from_axis(v3(0, 1, 0), 0.25)),
            v4_make(0.52, 0.50, 0.46, 1), v4_make(0.82, 0.0, 0.3, 1.0));

  { шкала материалов: от зеркала до матового, половина -- металл }
  for i := 0 to 7 do
  begin
    if i < 4 then
      batch_add(b_ball, mat4_of(v3(-4.2 + i * 1.3, 0.45, 3.6), q_identity),
                v4_make(0.95, 0.78, 0.42, 1),
                v4_make(0.05 + i * 0.3, 1.0, 0.5, 0.2))
    else
      batch_add(b_ball, mat4_of(v3(-4.2 + (i - 4) * 1.3, 0.45, 5.1), q_identity),
                v4_make(0.75, 0.22, 0.18, 1),
                v4_make(0.05 + (i - 4) * 0.3, 0.0, 0.9, 0.2));
  end;

  { персонажи }
  for i := 0 to nparts - 1 do
    for c := 0 to 2 do
    begin
      b := rd[c].part[i].body;
      case c of
        0: col := v4_make(0.30, 0.37, 0.33, 1);
        1: col := v4_make(0.42, 0.40, 0.36, 1);
      else
        col := v4_make(0.34, 0.30, 0.34, 1);
      end;
      if rd[c].part[i].bone = rd[c].bHead then
        col := v4_make(0.74, 0.58, 0.47, 1);
      batch_add(b_part[i], mat4_of(g_bodies[b].pos, g_bodies[b].orient),
                col, v4_make(0.72, 0.0, 0.35, 0.5));
    end;
end;

procedure draw_all(shadowPass: Boolean);
var i: Integer;

  procedure one(var bt: TBatch);
  begin
    if bt.n = 0 then Exit;
    if shadowPass then fox_shadow_draw(bt.mesh, bt.inst, bt.n)
    else fox_draw(bt.mesh, bt.inst, bt.n);
  end;

begin
  one(b_floor);
  one(b_wet);
  one(b_box);
  one(b_wall);
  one(b_ball);
  for i := 0 to nparts - 1 do one(b_part[i]);
end;

function make_fbo: Boolean;
begin
  glGenFramebuffers(1, @fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glGenRenderbuffers(1, @rbc);
  glBindRenderbuffer(GL_RENDERBUFFER, rbc);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, W, H);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_RENDERBUFFER, rbc);
  glGenRenderbuffers(1, @rbd);
  glBindRenderbuffer(GL_RENDERBUFFER, rbd);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, W, H);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                            GL_RENDERBUFFER, rbd);
  Result := glCheckFramebufferStatus(GL_FRAMEBUFFER) = GL_FRAMEBUFFER_COMPLETE;
end;

procedure save_bmp(const path: string);
var
  f: file;
  hdr: array[0..53] of Byte;
  row: array of Byte;
  x, y, srcp: Integer;
  rowsize, datasize: LongWord;
begin
  rowsize := ((W * 3 + 3) div 4) * 4;
  datasize := rowsize * H;
  FillChar(hdr, SizeOf(hdr), 0);
  hdr[0] := Ord('B'); hdr[1] := Ord('M');
  PLongWord(@hdr[2])^ := 54 + datasize;
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
  for y := 0 to H - 1 do
  begin
    FillChar(row[0], rowsize, 0);
    for x := 0 to W - 1 do
    begin
      srcp := (y * W + x) * 4;
      row[x * 3 + 0] := pixels[srcp + 2];
      row[x * 3 + 1] := pixels[srcp + 1];
      row[x * 3 + 2] := pixels[srcp + 0];
    end;
    BlockWrite(f, row[0], rowsize);
  end;
  CloseFile(f);
end;

var
  msg: string;
  i, c, k, dbg: Integer;
  t0: TDateTime;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);

  if not egl_headless_init(msg) then
  begin
    WriteLn('EGL: ', msg);
    Halt(1);
  end;
  if not gl_load_with(@eglGetProcAddress) then Halt(1);
  WriteLn('GL: ', glGetString(GL_VERSION), ' / ', glGetString(GL_RENDERER));
  if not make_fbo then Halt(1);

  if (ParamCount >= 1) and (ParamStr(1) = 'nogather') then fox_no_gather := True;
  if (ParamCount >= 1) and (ParamStr(1) = 'nossr') then fox_ssr := False;

  if not fox_init(W, H) then
  begin
    WriteLn('не удалось собрать конвейер');
    Halt(1);
  end;
  WriteLn('конвейер ufox собран');
  if fox_gather then
    WriteLn('  тени: 16 выборок через textureGather (GL_ARB_texture_gather)')
  else
    WriteLn('  тени: 9 выборок обычным texture (расширения нет)');
  if fox_ssr then WriteLn('  отражения в экранном пространстве: включены');

  { низкое солнце -- длинные тени, как в утренних кадрах MGS V }
  fox_sun_dir := v3_norm(v3(-0.74, -0.44, 0.26));
  fox_sun_color := v3(9.4, 8.0, 6.2);
  fox_sky_zenith := v3(0.17, 0.32, 0.66);
  fox_sky_horizon := v3(0.56, 0.63, 0.76);
  fox_ground_color := v3(0.21, 0.18, 0.14);
  fox_fog_color := v3(0.52, 0.56, 0.64);
  fox_fog_density := 0.0042;
  fox_fog_height := 34.0;
  fox_exposure := 0.34;
  fox_ssao_radius := 0.7;
  fox_ssao_power := 1.7;
  fox_update_sky;

  build_world;
  make_meshes;

  for k := 1 to 400 do
  begin
    for c := 0 to 2 do
      behave_update(rd[c], st[c], prm[c], animp, outp, 1.0 / 120.0);
    phys_step(1.0 / 120.0);
    if k = 60 then
      phys_apply_impulse(ragdoll_body_of_bone(rd[1], rd[1].bChest),
                         v3(-40, 0, 170),
                         g_bodies[ragdoll_body_of_bone(rd[1], rd[1].bChest)].pos);
    if k = 175 then Break;
  end;
  for c := 0 to 2 do
    WriteLn(Format('персонаж %d: ЦМ y=%.2f [%s]', [c, st[c].com.y, st[c].action]));

  camera_init(cam, v3(7.6, 2.05, 8.6));
  cam.yaw := -2.33;
  cam.pitch := -0.10;
  cam.fov := 42.0 * DEG2RAD;
  cam.znear := 0.1;
  cam.zfar := 160.0;
  camera_update(cam, W, H);

  fill_batches;

  t0 := Now;
  fox_verbose := True;
  { 1. тени }
  fox_shadow_setup(cam);
  if fox_shadows then
    for i := 0 to FOX_CASCADES - 1 do
    begin
      fox_shadow_begin(i);
      draw_all(True);
    end;
  fox_shadow_end;

  { 2. G-буфер }
  fox_gbuffer_begin(cam);
  draw_all(False);
  fox_gbuffer_end;

  if (ParamCount >= 1) and (ParamStr(1) = 'shadow') then fox_debug_light := 1.0;

  { 3. освещение и постобработка }
  fox_resolve(fbo);
  glFinish;
  WriteLn(Format('кадр нарисован за %.0f мс',
          [(Now - t0) * 24 * 60 * 60 * 1000]));
  WriteLn(Format('каскады: %.1f / %.1f / %.1f м', [cam.zfar*0.045, cam.zfar*0.14, cam.zfar]));
  if not gl_check('конвейер ufox') then Halt(1);

  SetLength(pixels, W * H * 4);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, @pixels[0]);
  if fox_no_gather then save_bmp('build/fox_nogather.bmp')
  else if not fox_ssr then save_bmp('build/fox_nossr.bmp')
  else save_bmp('build/fox.bmp');
  WriteLn('кадр сохранён');

  { отладочные выкладки буферов, если попросили }
  if ParamCount >= 1 then
  begin
    dbg := StrToIntDef(ParamStr(1), -1);
    if dbg >= 0 then
    begin
      fox_debug_blit(dbg, fbo);
      glFinish;
      glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, @pixels[0]);
      save_bmp('build/fox_debug.bmp');
      WriteLn('сохранено: build/fox_debug.bmp');
    end;
  end;

  egl_headless_done;
end.
