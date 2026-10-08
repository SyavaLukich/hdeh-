{ ============================================================================
  render_ragdoll.pas  --  кадр со скелетной анимацией, рэгдолом и реакциями

  Три персонажа в одной сцене, все из одного и того же кода:
    слева  -- стоит на мышцах, держит позу и ловит равновесие;
    в центре -- получил толчок, выставляет руки, падает;
    справа -- полностью расслаблен, обычная тряпичная кукла.

  Рисуется программным растеризатором (usoftgl), так что видеокарта
  не нужна:   make render-ragdoll  ->  build/ragdoll.png
  ============================================================================ }
program render_ragdoll;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugeom, ucamera, ugjk, uphysics, uskel, uragdoll,
  ubehave, usoftgl;

const
  W = 1280;
  H = 720;
  NCHARS = 3;

var
  vb_cap, vb_box: TVertexArray;
  ib_cap, ib_box: TIndexArray;
  vb_part: array[0..RD_MAX_PARTS - 1] of TVertexArray;
  ib_part: array[0..RD_MAX_PARTS - 1] of TIndexArray;

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

{ Геометрия для каждой части строится один раз по её размерам. }
procedure build_part_meshes;
var i: Integer;
begin
  for i := 0 to rd[0].nparts - 1 do
    if rd[0].part[i].isFoot then
      geom_box(v3(rd[0].part[i].halfW, rd[0].part[i].halfLen,
                  rd[0].part[i].halfH), vb_part[i], ib_part[i])
    else
      geom_capsule(rd[0].part[i].radius, rd[0].part[i].halfLen, 12, 8,
                   vb_part[i], ib_part[i]);
end;

procedure draw_char(c: Integer);
var
  i, b: Integer;
  m: TMat4;
  col: TVec4;
begin
  for i := 0 to rd[c].nparts - 1 do
  begin
    b := rd[c].part[i].body;
    m := m4_compose(g_bodies[b].pos, g_bodies[b].orient, v3(1, 1, 1));
    col := colr[c];
    { голову и кисти подсветим, чтобы читалась поза }
    if rd[c].part[i].bone = rd[c].bHead then
      col := v4_make(col.x * 1.25, col.y * 1.15, col.z * 1.0, 1);
    sg_draw(vb_part[i], ib_part[i], m, col);
  end;
end;

var
  i, c, k: Integer;
  root: TTransform;
  lowest: Single;
  camPos: TVec3;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);

  ragdoll_humanoid_skeleton(sk, 1.75);
  { строим рэгдол в естественной позе стоя, а не в позе привязки }
  ragdoll_idle_pose(sk, bindp);
  pose_copy(bindp, animp);

  { где низ персонажа в позе привязки }
  phys_init;
  root.pos := v3_zero; root.rot := q_identity;
  ragdoll_build(rd[0], sk, bindp, root, 70);
  lowest := 1.0e9;
  for i := 0 to rd[0].nparts - 1 do
    lowest := fmin(lowest, g_bodies[rd[0].part[i].body].box.mn.y);
  groundY := -lowest;

  { ---- сцена ---- }
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
  prm[2].flags := [];                       { тряпка }

  build_part_meshes;

  { ---- прогон ---- }
  for k := 1 to 400 do
  begin
    for c := 0 to NCHARS - 1 do
      behave_update(rd[c], st[c], prm[c], animp, outp, 1.0 / 120.0);
    phys_step(1.0 / 120.0);

    { на 0.6 с толкаем среднего в грудь }
    if k = 72 then
      phys_apply_impulse(ragdoll_body_of_bone(rd[1], rd[1].bChest),
                         v3(0, 0, 150),
                         g_bodies[ragdoll_body_of_bone(rd[1], rd[1].bChest)].pos);
    { кадр берём на 1.6 с -- средний как раз в падении }
    if k = 190 then Break;
  end;

  for c := 0 to NCHARS - 1 do
    WriteLn(Format('персонаж %d: ЦМ y=%.2f, опора=%d, тонус=%.2f [%s]',
            [c, st[c].com.y, st[c].footContacts, st[c].effTone, st[c].action]));

  { ---- картинка ---- }
  camPos := v3(3.4, 1.55, 4.2);
  camera_init(sg_cam, camPos);
  sg_cam.yaw := -2.33;
  sg_cam.pitch := -0.16;
  sg_cam.fov := 48.0 * DEG2RAD;
  camera_update(sg_cam, W, H);

  sg_fog_near := 14;
  sg_fog_far := 70;
  sg_init(W, H, sg_fog_color);

  geom_box(v3(30, 1, 30), vb_box, ib_box);
  sg_draw(vb_box, ib_box, m4_compose(v3(0, -1, 0), q_identity, v3(1, 1, 1)),
          v4_make(0.45, 0.48, 0.42, 1));

  for c := 0 to NCHARS - 1 do draw_char(c);

  WriteLn(Format('кадр: треугольников %d, пикселей %d', [sg_tris, sg_pixels]));
  sg_save_bmp('build/ragdoll.bmp');
  WriteLn('сохранено: build/ragdoll.bmp');
  if vb_cap = nil then ;
  if ib_cap = nil then ;
end.
