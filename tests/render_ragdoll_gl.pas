{ ============================================================================
  render_ragdoll.pas  --  кадр со скелетной анимацией, рэгдолом и реакциями

  Три персонажа в одной сцене, все из одного и того же кода:
    слева  -- стоит на мышцах, держит позу и ловит равновесие;
    в центре -- получил толчок, выставляет руки, падает;
    справа -- полностью расслаблен, обычная тряпичная кукла.

  Рисуется НАСТОЯЩИМ OpenGL 3.3 через EGL (surfaceless), то есть тем же
  путём, что и демо: шейдеры компилирует драйвер, геометрия лежит в VBO,
  части тела рисуются инстансингом.

      make render-ragdoll-gl  ->  build/ragdoll_gl.png
  ============================================================================ }
program render_ragdoll_gl;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugl, ugeom, ucamera, umesh, urender, ugjk, uphysics,
  uskel, uragdoll, ubehave, uegl;

const
  W = 1280;
  H = 720;
  NCHARS = 3;

var
  mesh_part: array[0..RD_MAX_PARTS - 1] of TMesh;
  inst_part: array[0..RD_MAX_PARTS - 1] of array[0..NCHARS - 1] of TInstance;
  mesh_floor: TMesh;
  inst_floor: array[0..0] of TInstance;
  cam: TCamera;
  fbo, rbc, rbd: GLuint;
  pixels: array of Byte;

  sk: TSkeleton;
  bindp: TSkelPose;
  rd: array[0..NCHARS - 1] of TRagdoll;
  st: array[0..NCHARS - 1] of TBehaveState;
  prm: array[0..NCHARS - 1] of TBehaveParams;
  animp, outp: TSkelPose;
  colr: array[0..NCHARS - 1] of TVec4;
  floorBody: Integer;
  groundY: Single;

procedure make_floor;
var pts: array[0..7] of TVec3;
begin
  pts[0] := v3(-30, -1, -30); pts[1] := v3(30, -1, -30);
  pts[2] := v3(-30,  1, -30); pts[3] := v3(30,  1, -30);
  pts[4] := v3(-30, -1,  30); pts[5] := v3(30, -1,  30);
  pts[6] := v3(-30,  1,  30); pts[7] := v3(30,  1,  30);
  floorBody := phys_add_body(shape_hull(pts), v3(0, -1, 0), q_identity, 0);
  phys_set_material(floorBody, 0.95, 0.0);
end;

{ Для каждой части -- своя сетка в видеопамяти, по одному экземпляру
  на персонажа. Ровно тот же путь, что у демо. }
procedure build_part_meshes;
var i: Integer;
begin
  for i := 0 to rd[0].nparts - 1 do
  begin
    if rd[0].part[i].isFoot then
      mesh_part[i] := mesh_make_box(v3(rd[0].part[i].halfW,
                                       rd[0].part[i].halfLen,
                                       rd[0].part[i].halfH))
    else
      mesh_part[i] := mesh_make_capsule(rd[0].part[i].radius,
                                        rd[0].part[i].halfLen, 12, 8);
    mesh_enable_instancing(mesh_part[i], NCHARS);
  end;
  mesh_floor := mesh_make_box(v3(30, 1, 30));
  mesh_enable_instancing(mesh_floor, 1);
end;

procedure fill_instances;
var
  i, c, b: Integer;
  col: TVec4;
begin
  for i := 0 to rd[0].nparts - 1 do
    for c := 0 to NCHARS - 1 do
    begin
      b := rd[c].part[i].body;
      inst_part[i][c].model := m4_compose(g_bodies[b].pos,
                                          g_bodies[b].orient, v3(1, 1, 1));
      col := colr[c];
      if rd[c].part[i].bone = rd[c].bHead then
        col := v4_make(col.x * 1.25, col.y * 1.15, col.z, 1);
      inst_part[i][c].color := col;
    end;
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
  i, c, k: Integer;
  root: TTransform;
  lowest: Single;
  msg: string;
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
  glViewport(0, 0, W, H);
  if not render_init then Halt(1);

  ragdoll_humanoid_skeleton(sk, 1.75);
  ragdoll_idle_pose(sk, bindp);
  pose_copy(bindp, animp);

  phys_init;
  root.pos := v3_zero; root.rot := q_identity;
  ragdoll_build(rd[0], sk, bindp, root, 70);
  lowest := 1.0e9;
  for i := 0 to rd[0].nparts - 1 do
    lowest := fmin(lowest, g_bodies[rd[0].part[i].body].box.mn.y);
  groundY := -lowest;

  phys_init;
  make_floor;
  for c := 0 to NCHARS - 1 do
  begin
    root.pos := v3(-1.6 + c * 1.6, groundY, 0);
    root.rot := q_from_axis(v3(0, 1, 0), -0.25 + c * 0.25);
    ragdoll_build(rd[c], sk, bindp, root, 70);
    behave_defaults(prm[c]);
    behave_init(st[c]);
  end;
  colr[0] := v4_make(0.42, 0.62, 0.85, 1);
  colr[1] := v4_make(0.88, 0.62, 0.30, 1);
  colr[2] := v4_make(0.72, 0.42, 0.52, 1);
  prm[0].flags := [BH_TONE, BH_BALANCE, BH_STEP];
  prm[1].flags := [BH_TONE, BH_BALANCE, BH_STEP, BH_PROTECT, BH_TUCK, BH_WINDMILL];
  prm[2].flags := [];

  build_part_meshes;

  for k := 1 to 400 do
  begin
    for c := 0 to NCHARS - 1 do
      behave_update(rd[c], st[c], prm[c], animp, outp, 1.0 / 120.0);
    phys_step(1.0 / 120.0);
    if k = 72 then
      phys_apply_impulse(ragdoll_body_of_bone(rd[1], rd[1].bChest),
                         v3(0, 0, 150),
                         g_bodies[ragdoll_body_of_bone(rd[1], rd[1].bChest)].pos);
    if k = 190 then Break;
  end;

  for c := 0 to NCHARS - 1 do
    WriteLn(Format('персонаж %d: ЦМ y=%.2f, опора=%d, тонус=%.2f [%s]',
            [c, st[c].com.y, st[c].footContacts, st[c].effTone, st[c].action]));

  camera_init(cam, v3(3.4, 1.55, 4.2));
  cam.yaw := -2.33;
  cam.pitch := -0.16;
  cam.fov := 48.0 * DEG2RAD;
  camera_update(cam, W, H);
  g_fog_near := 14;
  g_fog_far := 70;

  render_begin(cam);
  render_lit_begin(cam);

  inst_floor[0].model := m4_compose(v3(0, -1, 0), q_identity, v3(1, 1, 1));
  inst_floor[0].color := v4_make(0.45, 0.48, 0.42, 1);
  render_draw_batch(mesh_floor, inst_floor, 1);

  fill_instances;
  for i := 0 to rd[0].nparts - 1 do
    render_draw_batch(mesh_part[i], inst_part[i], NCHARS);
  glFinish;
  if not gl_check('отрисовка рэгдолов') then Halt(1);

  SetLength(pixels, W * H * 4);
  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, @pixels[0]);
  save_bmp('build/ragdoll_gl.bmp');
  WriteLn('сохранено: build/ragdoll_gl.bmp');

  render_shutdown;
  egl_headless_done;
end.
