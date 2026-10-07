{ ============================================================================
  uragdoll.pas  --  рэгдол: скелет, превращённый в связку физических тел

  Каждая значимая кость получает капсулу, каждое сочленение -- шаровой
  сустав с анатомическими пределами. Обратно из физики читается ПОЗА в том
  же виде, в каком её выдаёт анимация, поэтому между анимацией и рэгдолом
  можно плавно смешиваться покостно.

  Важная деталь: у сустава есть мотор. Выключенный мотор -- это "тряпичная
  кукла", классический рэгдол. Включённый мотор, которому скармливают позу
  из анимации, -- это уже мышцы: персонаж пытается держать позу, но
  настоящая физика может ему помешать. На этом и построен слой поведения
  в ubehave.pas.
  ============================================================================ }
unit uragdoll;

{$MODE OBJFPC}
{$H+}

interface

uses
  SysUtils, Math, umath, ugjk, uphysics, uskel;

const
  RD_MAX_PARTS = 24;

type
  TRagdollPart = record
    bone     : Integer;      { кость скелета }
    body     : Integer;      { тело в физике }
    halfLen  : Single;       { половина длины капсулы (или стопы) }
    radius   : Single;
    halfW    : Single;       { для стопы: полуширина и полувысота ящика }
    halfH    : Single;
    isFoot   : Boolean;
    { Кватернион выравнивания: ось капсулы (+Y тела) вдоль кости.
      Мировая ориентация кости = ориентация тела * conj(align). }
    align    : TQuat;
    massFrac : Single;
  end;

  TRagdollJoint = record
    joint      : Integer;    { индекс сустава в физике }
    bone       : Integer;    { дочерняя кость }
    parentPart : Integer;
    childPart  : Integer;
    restTarget : TQuat;      { целевая ориентация в системе сустава }
    baseTorque : Single;     { максимальный момент при полном тонусе }
    baseStiff  : Single;
  end;

  TRagdoll = record
    skel       : TSkeleton;
    { Поза, в которой рэгдол был собран. Нули суставов отсчитываются
      именно от неё, а не от позы привязки скелета. }
    restPose   : TSkelPose;
    nparts     : Integer;
    part       : array[0..RD_MAX_PARTS - 1] of TRagdollPart;
    boneToPart : array[0..SK_MAX_BONES - 1] of Integer;
    njoints    : Integer;
    joint      : array[0..RD_MAX_PARTS - 1] of TRagdollJoint;
    rootPart   : Integer;
    totalMass  : Single;
    tone       : Single;     { общий мышечный тонус 0..1 }
    { имена ключевых костей, чтобы слой поведения не искал их строками }
    bHips, bSpine, bChest, bHead          : Integer;
    bArmL, bArmR, bForeL, bForeR          : Integer;
    bThighL, bThighR, bShinL, bShinR      : Integer;
    bFootL, bFootR                        : Integer;
  end;

{ Готовый гуманоидный скелет заданного роста (метры). }
procedure ragdoll_humanoid_skeleton(out s: TSkeleton; height: Single);
{ Естественная поза стоя: руки опущены вдоль тела, локти и колени чуть
  согнуты. Поза привязки у нас "крестом" -- для анимации так удобнее,
  но стоять в ней человек не станет. }
procedure ragdoll_idle_pose(const s: TSkeleton; out p: TSkelPose);

{ Строит физические тела и суставы по скелету и позе.
  rootXform задаёт, где персонаж стоит в мире. }
procedure ragdoll_build(out rd: TRagdoll; const s: TSkeleton;
                        const p: TSkelPose; const rootXform: TTransform;
                        totalMass: Single);

{ Физика -> поза (локальные трансформы) и мировой трансформ корня. }
procedure ragdoll_read_pose(const rd: TRagdoll; var p: TSkelPose;
                            out rootXform: TTransform);

{ Поза -> цели моторов. Это и есть "задать мышцам, что делать". }
procedure ragdoll_drive_pose(var rd: TRagdoll; const p: TSkelPose);

{ Общий мышечный тонус: 0 -- полная тряпка, 1 -- полная сила. }
procedure ragdoll_set_tone(var rd: TRagdoll; tone: Single);
{ Тонус отдельной цепи (например, только рук). }
procedure ragdoll_set_chain_tone(var rd: TRagdoll; rootBone: Integer;
                                 tone: Single);

function  ragdoll_com(const rd: TRagdoll): TVec3;
function  ragdoll_com_vel(const rd: TRagdoll): TVec3;
function  ragdoll_body_of_bone(const rd: TRagdoll; bone: Integer): Integer;
function  ragdoll_part_world(const rd: TRagdoll; part: Integer): TTransform;
{ Суммарный импульс контактов, пришедшийся на рэгдол за прошлый шаг. }
function  ragdoll_impact(const rd: TRagdoll; out point, dir: TVec3): Single;
procedure ragdoll_add_impulse(var rd: TRagdoll; bone: Integer;
                              const imp: TVec3);

implementation

{ =========================================================================
  Гуманоидный скелет

  Пропорции взяты усреднённые: голова ~1/7.5 роста, нога ~0.53 роста.
  Все повороты в позе привязки единичные -- персонаж стоит ровно,
  руки опущены вдоль тела.
  ========================================================================= }

{ Восемь вершин ящика с полуразмерами (hx, hy, hz). }
procedure box_points(hx, hy, hz: Single; out pts: array of TVec3);
var
  i: Integer;
  sx, sy, sz: Single;
begin
  for i := 0 to 7 do
  begin
    if (i and 1) <> 0 then sx := 1 else sx := -1;
    if (i and 2) <> 0 then sy := 1 else sy := -1;
    if (i and 4) <> 0 then sz := 1 else sz := -1;
    pts[i] := v3(hx * sx, hy * sy, hz * sz);
  end;
end;

function xf(const p: TVec3): TTransform; inline;
begin
  Result.pos := p;
  Result.rot := q_identity;
end;

procedure ragdoll_humanoid_skeleton(out s: TSkeleton; height: Single);
var
  k, hipY, spineL, chestL, neckL, headL: Single;
  armU, armF, handL, thighL_, shinL_, footL_: Single;
  shoulderX, hipX: Single;
  bHips, bSpine, bChest, bNeck: Integer;
  bClavL, bClavR, bArmL, bArmR, bForeL, bForeR: Integer;
  bThighL, bThighR, bShinL, bShinR, bFootL, bFootR: Integer;
begin
  skel_clear(s);
  k := height / 1.75;                 { все размеры -- от роста 1.75 }

  hipY   := 0.95 * k;
  spineL := 0.16 * k;
  chestL := 0.20 * k;
  neckL  := 0.16 * k;
  headL  := 0.14 * k;
  armU   := 0.28 * k;
  armF   := 0.26 * k;
  handL  := 0.10 * k;
  thighL_:= 0.44 * k;
  shinL_ := 0.43 * k;
  footL_ := 0.16 * k;
  shoulderX := 0.18 * k;
  hipX      := 0.09 * k;

  bHips  := skel_add_bone(s, 'hips',  SK_ROOT, xf(v3(0, hipY, 0)));
  bSpine := skel_add_bone(s, 'spine', bHips,   xf(v3(0, spineL, 0)));
  bChest := skel_add_bone(s, 'chest', bSpine,  xf(v3(0, chestL, 0)));
  bNeck  := skel_add_bone(s, 'neck',  bChest,  xf(v3(0, neckL, 0)));
                skel_add_bone(s, 'head',  bNeck, xf(v3(0, headL, 0)));

  bClavL := skel_add_bone(s, 'clavL', bChest, xf(v3(shoulderX * 0.4, neckL * 0.6, 0)));
  bArmL  := skel_add_bone(s, 'armL',  bClavL, xf(v3(shoulderX * 0.6, 0, 0)));
  bForeL := skel_add_bone(s, 'foreL', bArmL,  xf(v3(armU, 0, 0)));
                skel_add_bone(s, 'handL', bForeL, xf(v3(armF, 0, 0)));

  bClavR := skel_add_bone(s, 'clavR', bChest, xf(v3(-shoulderX * 0.4, neckL * 0.6, 0)));
  bArmR  := skel_add_bone(s, 'armR',  bClavR, xf(v3(-shoulderX * 0.6, 0, 0)));
  bForeR := skel_add_bone(s, 'foreR', bArmR,  xf(v3(-armU, 0, 0)));
                skel_add_bone(s, 'handR', bForeR, xf(v3(-armF, 0, 0)));

  bThighL := skel_add_bone(s, 'thighL', bHips,   xf(v3(hipX, -0.05 * k, 0)));
  bShinL  := skel_add_bone(s, 'shinL',  bThighL, xf(v3(0, -thighL_, 0)));
  bFootL  := skel_add_bone(s, 'footL',  bShinL,  xf(v3(0, -shinL_, 0)));
                skel_add_bone(s, 'toeL', bFootL, xf(v3(0, -0.04 * k, footL_)));

  bThighR := skel_add_bone(s, 'thighR', bHips,   xf(v3(-hipX, -0.05 * k, 0)));
  bShinR  := skel_add_bone(s, 'shinR',  bThighR, xf(v3(0, -thighL_, 0)));
  bFootR  := skel_add_bone(s, 'footR',  bShinR,  xf(v3(0, -shinL_, 0)));
                skel_add_bone(s, 'toeR', bFootR, xf(v3(0, -0.04 * k, footL_)));

  { подавляем предупреждения о неиспользуемых }
  if (bForeR < 0) or (handL < 0) then ;

  skel_finalize(s);
end;

procedure ragdoll_idle_pose(const s: TSkeleton; out p: TSkelPose);
var b: Integer;

  procedure turn(const name: string; const axis: TVec3; ang: Single);
  var i: Integer;
  begin
    i := skel_find(s, name);
    if i >= 0 then
      p.local[i].rot := q_norm(q_mul(q_from_axis(axis, ang), p.local[i].rot));
  end;

begin
  pose_bind(s, p);
  { руки вниз: поворот вокруг Z опускает кость, идущую вдоль X }
  turn('armL',  v3(0, 0, 1), -1.35);
  turn('armR',  v3(0, 0, 1),  1.35);
  turn('foreL', v3(0, 1, 0), -0.25);
  turn('foreR', v3(0, 1, 0),  0.25);
  turn('foreL', v3(0, 0, 1), -0.18);
  turn('foreR', v3(0, 0, 1),  0.18);
  { лёгкий присед: колени и голеностоп компенсируют друг друга }
  { Колени почти прямые: согнутая стойка требует отдельного контура
    управления коленом, которого здесь нет, и заметно хуже держится. }
  turn('thighL', v3(1, 0, 0), -0.03);
  turn('thighR', v3(1, 0, 0), -0.03);
  turn('shinL',  v3(1, 0, 0),  0.06);
  turn('shinR',  v3(1, 0, 0),  0.06);
  turn('footL',  v3(1, 0, 0), -0.03);
  turn('footR',  v3(1, 0, 0), -0.03);
  b := 0;
  if b <> 0 then ;
end;

{ =========================================================================
  Построение тел и суставов
  ========================================================================= }

{ Таблица: какие кости получают тело, их доля массы и толщина. }
type
  TPartSpec = record
    name    : string[15];
    massFrac: Single;
    radFrac : Single;   { радиус капсулы как доля длины кости }
  end;

const
  PART_SPECS: array[0..16] of TPartSpec = (
    (name: 'clavL';  massFrac: 0.012; radFrac: 0.40),
    (name: 'clavR';  massFrac: 0.012; radFrac: 0.40),
    (name: 'hips';   massFrac: 0.14; radFrac: 0.55),
    (name: 'spine';  massFrac: 0.13; radFrac: 0.60),
    (name: 'chest';  massFrac: 0.17; radFrac: 0.62),
    (name: 'head';   massFrac: 0.07; radFrac: 0.75),
    (name: 'armL';   massFrac: 0.028; radFrac: 0.17),
    (name: 'foreL';  massFrac: 0.022; radFrac: 0.15),
    (name: 'armR';   massFrac: 0.028; radFrac: 0.17),
    (name: 'foreR';  massFrac: 0.022; radFrac: 0.15),
    (name: 'thighL'; massFrac: 0.105; radFrac: 0.20),
    (name: 'shinL';  massFrac: 0.050; radFrac: 0.16),
    (name: 'footL';  massFrac: 0.015; radFrac: 0.35),
    (name: 'thighR'; massFrac: 0.105; radFrac: 0.20),
    (name: 'shinR';  massFrac: 0.050; radFrac: 0.16),
    (name: 'footR';  massFrac: 0.015; radFrac: 0.35),
    (name: 'neck';   massFrac: 0.02; radFrac: 0.45)
  );

{ Пределы суставов. Ось X сустава идёт вдоль кости (кручение),
  Y -- основная ось сгиба. }
type
  TJointSpec = record
    name    : string[15];
    swingY  : Single;    { сгиб в основной плоскости }
    swingZ  : Single;    { отведение вбок }
    twistLo : Single;
    twistHi : Single;
    torque  : Single;    { Н*м при полном тонусе }
    stiff   : Single;
  end;

const
  JOINT_SPECS: array[0..15] of TJointSpec = (
    (name: 'clavL';  swingY: 0.25; swingZ: 0.25; twistLo: -0.15; twistHi: 0.15; torque: 150; stiff: 20),
    (name: 'clavR';  swingY: 0.25; swingZ: 0.25; twistLo: -0.15; twistHi: 0.15; torque: 150; stiff: 20),
    (name: 'spine';  swingY: 0.40; swingZ: 0.30; twistLo: -0.40; twistHi: 0.40; torque: 260; stiff: 16),
    (name: 'chest';  swingY: 0.35; swingZ: 0.25; twistLo: -0.35; twistHi: 0.35; torque: 240; stiff: 16),
    (name: 'neck';   swingY: 0.60; swingZ: 0.50; twistLo: -0.70; twistHi: 0.70; torque:  60; stiff: 18),
    (name: 'head';   swingY: 0.45; swingZ: 0.40; twistLo: -0.50; twistHi: 0.50; torque:  45; stiff: 18),
    (name: 'armL';   swingY: 1.50; swingZ: 1.20; twistLo: -1.00; twistHi: 1.00; torque: 110; stiff: 14),
    (name: 'foreL';  swingY: 2.30; swingZ: 0.06; twistLo: -0.20; twistHi: 0.20; torque:  70; stiff: 16),
    (name: 'armR';   swingY: 1.50; swingZ: 1.20; twistLo: -1.00; twistHi: 1.00; torque: 110; stiff: 14),
    (name: 'foreR';  swingY: 2.30; swingZ: 0.06; twistLo: -0.20; twistHi: 0.20; torque:  70; stiff: 16),
    (name: 'thighL'; swingY: 1.30; swingZ: 0.55; twistLo: -0.40; twistHi: 0.40; torque: 320; stiff: 16),
    (name: 'shinL';  swingY: 2.20; swingZ: 0.05; twistLo: -0.10; twistHi: 0.10; torque: 240; stiff: 18),
    (name: 'footL';  swingY: 0.70; swingZ: 0.35; twistLo: -0.30; twistHi: 0.30; torque: 120; stiff: 20),
    (name: 'thighR'; swingY: 1.30; swingZ: 0.55; twistLo: -0.40; twistHi: 0.40; torque: 320; stiff: 16),
    (name: 'shinR';  swingY: 2.20; swingZ: 0.05; twistLo: -0.10; twistHi: 0.10; torque: 240; stiff: 18),
    (name: 'footR';  swingY: 0.70; swingZ: 0.35; twistLo: -0.30; twistHi: 0.30; torque: 120; stiff: 20)
  );

function find_spec(const name: string): Integer;
var i: Integer;
begin
  for i := 0 to High(JOINT_SPECS) do
    if JOINT_SPECS[i].name = name then
    begin
      Result := i;
      Exit;
    end;
  Result := -1;
end;

{ Ближайший предок кости, у которого есть физическое тело. }
function parent_part(const rd: TRagdoll; bone: Integer): Integer;
var p: Integer;
begin
  Result := -1;
  p := rd.skel.bone[bone].parent;
  while p >= 0 do
  begin
    if rd.boneToPart[p] >= 0 then
    begin
      Result := rd.boneToPart[p];
      Exit;
    end;
    p := rd.skel.bone[p].parent;
  end;
end;

procedure ragdoll_build(out rd: TRagdoll; const s: TSkeleton;
                        const p: TSkelPose; const rootXform: TTransform;
                        totalMass: Single);
var
  w: TSkelPose;
  i, si, bone, pp, jid, spec: Integer;
  dirW, mid, anchor, hinge: TVec3;
  bpts: array[0..7] of TVec3;
  qBody: TQuat;
  len, rad, mass: Single;
  prt: ^TRagdollPart;
begin
  FillChar(rd, SizeOf(TRagdoll), 0);
  rd.skel := s;
  pose_copy(p, rd.restPose);
  rd.totalMass := totalMass;
  rd.tone := 1.0;
  for i := 0 to SK_MAX_BONES - 1 do rd.boneToPart[i] := -1;

  skel_world(s, p, rootXform, w);

  { ---- тела ---- }
  for si := 0 to High(PART_SPECS) do
  begin
    bone := skel_find(s, PART_SPECS[si].name);
    if bone < 0 then Continue;

    len := s.bone[bone].length;
    if len < 0.02 then len := 0.02;
    rad := len * PART_SPECS[si].radFrac;
    if rad < 0.02 then rad := 0.02;
    if rad > len * 0.9 then rad := len * 0.9;

    prt := @rd.part[rd.nparts];
    prt^.bone := bone;
    prt^.halfLen := fmax(len * 0.5 - rad, 0.01);
    prt^.radius := rad;
    { ось тела +Y выравнивается на направление кости }
    prt^.align := q_from_to(v3(0, 1, 0), s.bone[bone].dirLocal);
    prt^.massFrac := PART_SPECS[si].massFrac;
    prt^.isFoot := (PART_SPECS[si].name = 'footL') or
                   (PART_SPECS[si].name = 'footR');

    qBody := q_mul(w.local[bone].rot, prt^.align);
    dirW := q_rotate(w.local[bone].rot,
                     v3_mul(s.bone[bone].dirLocal, len));
    mass := totalMass * PART_SPECS[si].massFrac;

    if prt^.isFoot then
    begin
      { Стопа -- плоский ящик, а не капсула. Это принципиально: круглая
        стопа даёт точечный контакт, и голеностоп физически не может
        создать момент, которым тело удерживает равновесие. Ящик даёт
        площадь опоры -- появляется и пятка, и носок. }
      prt^.halfLen := len * 0.75;
      prt^.radius := len * 0.28;
      prt^.halfW := len * 0.30;
      prt^.halfH := len * 0.16;
      { центр смещён назад, чтобы за голеностопом осталась пятка }
      mid := v3_add(w.local[bone].pos,
                    v3_mul(v3_norm(dirW), prt^.halfLen - len * 0.45));
      box_points(prt^.halfW, prt^.halfLen, prt^.halfH, bpts);
      prt^.body := phys_add_body(shape_hull(bpts), mid, qBody, mass);
    end
    else
    begin
      mid := v3_add(w.local[bone].pos, v3_mul(dirW, 0.5));
      prt^.body := phys_add_body(shape_capsule(rad, prt^.halfLen),
                                 mid, qBody, mass);
    end;
    if prt^.isFoot then
      phys_set_material(prt^.body, 1.0, 0.0)
    else
      phys_set_material(prt^.body, 0.75, 0.0);
    g_bodies[prt^.body].angDamp := 0.12;
    g_bodies[prt^.body].linDamp := 0.04;
    g_bodies[prt^.body].userTag := 1000 + bone;

    rd.boneToPart[bone] := rd.nparts;
    Inc(rd.nparts);
  end;

  rd.rootPart := rd.boneToPart[skel_find(s, 'hips')];

  { ---- суставы ---- }
  for i := 0 to rd.nparts - 1 do
  begin
    bone := rd.part[i].bone;
    pp := parent_part(rd, bone);
    if pp < 0 then Continue;

    anchor := w.local[bone].pos;
    { ось кручения -- вдоль кости; ось сгиба -- поперёк, в плоскости тела }
    dirW := q_rotate(w.local[bone].rot, s.bone[bone].dirLocal);
    hinge := v3_cross(dirW, v3(0, 0, 1));
    if v3_lensq(hinge) < 1.0e-5 then hinge := v3_cross(dirW, v3(0, 1, 0));

    jid := phys_add_joint_axes(JT_BALL, rd.part[pp].body, rd.part[i].body,
                               anchor, dirW, hinge);
    if jid < 0 then Continue;

    rd.joint[rd.njoints].joint := jid;
    rd.joint[rd.njoints].bone := bone;
    rd.joint[rd.njoints].parentPart := pp;
    rd.joint[rd.njoints].childPart := i;
    rd.joint[rd.njoints].restTarget := q_identity;

    spec := find_spec(s.bone[bone].name);
    if spec >= 0 then
    begin
      phys_joint_limits(jid, JOINT_SPECS[spec].swingY, JOINT_SPECS[spec].swingZ,
                        JOINT_SPECS[spec].twistLo, JOINT_SPECS[spec].twistHi);
      rd.joint[rd.njoints].baseTorque := JOINT_SPECS[spec].torque;
      rd.joint[rd.njoints].baseStiff := JOINT_SPECS[spec].stiff;
    end
    else
    begin
      phys_joint_limits(jid, 0.5, 0.5, -0.5, 0.5);
      rd.joint[rd.njoints].baseTorque := 80;
      rd.joint[rd.njoints].baseStiff := 14;
    end;
    phys_joint_motor(jid, True, rd.joint[rd.njoints].baseStiff, 1.0,
                     rd.joint[rd.njoints].baseTorque);
    Inc(rd.njoints);
  end;

  { Соседи через одного тоже не должны толкаться: бедро и голень уже
    связаны суставом, а вот бедро и стопа перекрываются геометрически. }
  for i := 0 to rd.njoints - 1 do
  begin
    pp := parent_part(rd, rd.skel.bone[rd.joint[i].bone].parent);
    if pp >= 0 then
      phys_ignore_pair(rd.part[pp].body, rd.part[rd.joint[i].childPart].body);
  end;

  rd.bHips   := skel_find(s, 'hips');
  rd.bSpine  := skel_find(s, 'spine');
  rd.bChest  := skel_find(s, 'chest');
  rd.bHead   := skel_find(s, 'head');
  rd.bArmL   := skel_find(s, 'armL');
  rd.bArmR   := skel_find(s, 'armR');
  rd.bForeL  := skel_find(s, 'foreL');
  rd.bForeR  := skel_find(s, 'foreR');
  rd.bThighL := skel_find(s, 'thighL');
  rd.bThighR := skel_find(s, 'thighR');
  rd.bShinL  := skel_find(s, 'shinL');
  rd.bShinR  := skel_find(s, 'shinR');
  rd.bFootL  := skel_find(s, 'footL');
  rd.bFootR  := skel_find(s, 'footR');
end;

{ =========================================================================
  Чтение и запись позы
  ========================================================================= }

function ragdoll_part_world(const rd: TRagdoll; part: Integer): TTransform;
var
  b: Integer;
  qBone: TQuat;
  len, back: Single;
begin
  b := rd.part[part].body;
  qBone := q_mul(g_bodies[b].orient, q_conj(rd.part[part].align));
  len := rd.skel.bone[rd.part[part].bone].length;
  Result.rot := qBone;
  { Начало кости отступает от центра тела назад вдоль кости. }
  if rd.part[part].isFoot then
    back := rd.part[part].halfLen - len * 0.45
  else
    back := len * 0.5;
  Result.pos := v3_sub(g_bodies[b].pos,
                       q_rotate(qBone,
                                v3_mul(rd.skel.bone[rd.part[part].bone].dirLocal,
                                       back)));
end;

procedure ragdoll_read_pose(const rd: TRagdoll; var p: TSkelPose;
                            out rootXform: TTransform);
var
  wpose: TSkelPose;
  i, par: Integer;
  pw, inv: TTransform;
begin
  { 1. мировые трансформы симулируемых костей }
  wpose.n := rd.skel.nbones;
  for i := 0 to rd.skel.nbones - 1 do
    wpose.local[i].rot := q_identity;

  for i := 0 to rd.nparts - 1 do
    wpose.local[rd.part[i].bone] := ragdoll_part_world(rd, i);

  { 2. кости без тела следуют за ближайшим предком с телом }
  for i := 0 to rd.skel.nbones - 1 do
    if rd.boneToPart[i] < 0 then
    begin
      par := rd.skel.bone[i].parent;
      if par < 0 then
        wpose.local[i] := rd.skel.bone[i].bindWorld
      else
      begin
        wpose.local[i].rot := q_mul(wpose.local[par].rot,
                                    rd.skel.bone[i].bind.rot);
        wpose.local[i].pos := v3_add(wpose.local[par].pos,
                                     q_rotate(wpose.local[par].rot,
                                              rd.skel.bone[i].bind.pos));
      end;
    end;

  { 3. Корень позы -- мировой трансформ нулевой кости. Локальные
       трансформы ниже считаются уже относительно него. }
  rootXform := wpose.local[0];

  { 4. мировые -> локальные }
  p.n := rd.skel.nbones;
  for i := 0 to rd.skel.nbones - 1 do
  begin
    par := rd.skel.bone[i].parent;
    if par < 0 then
    begin
      p.local[i].rot := q_identity;
      p.local[i].pos := v3_zero;
    end
    else
    begin
      pw := wpose.local[par];
      inv.rot := q_conj(pw.rot);
      p.local[i].rot := q_mul(inv.rot, wpose.local[i].rot);
      p.local[i].pos := q_rotate(inv.rot, v3_sub(wpose.local[i].pos, pw.pos));
    end;
  end;
end;

procedure ragdoll_drive_pose(var rd: TRagdoll; const p: TSkelPose);
var
  i, bone: Integer;
  qTarget: TQuat;
begin
  for i := 0 to rd.njoints - 1 do
  begin
    bone := rd.joint[i].bone;
    { Поза задаёт локальный поворот кости относительно родителя.
      Система сустава совпадает с позой привязки, поэтому цель --
      это отклонение от привязки. }
    { Ноль сустава -- поза сборки, поэтому цель считается от неё. }
    qTarget := q_mul(q_conj(rd.restPose.local[bone].rot), p.local[bone].rot);
    rd.joint[i].restTarget := qTarget;
    phys_joint_target(rd.joint[i].joint, qTarget);
  end;
end;

procedure ragdoll_set_tone(var rd: TRagdoll; tone: Single);
var i: Integer;
begin
  rd.tone := fclamp(tone, 0, 1);
  for i := 0 to rd.njoints - 1 do
    phys_joint_motor(rd.joint[i].joint, rd.tone > 0.001,
                     rd.joint[i].baseStiff * (0.35 + 0.65 * rd.tone),
                     1.0,
                     rd.joint[i].baseTorque * rd.tone);
end;

procedure ragdoll_set_chain_tone(var rd: TRagdoll; rootBone: Integer;
                                 tone: Single);
var
  i, b: Integer;
  inChain: Boolean;
begin
  tone := fclamp(tone, 0, 1);
  for i := 0 to rd.njoints - 1 do
  begin
    b := rd.joint[i].bone;
    inChain := False;
    while b >= 0 do
    begin
      if b = rootBone then
      begin
        inChain := True;
        Break;
      end;
      b := rd.skel.bone[b].parent;
    end;
    if inChain then
      phys_joint_motor(rd.joint[i].joint, tone > 0.001,
                       rd.joint[i].baseStiff * (0.35 + 0.65 * tone), 1.0,
                       rd.joint[i].baseTorque * tone);
  end;
end;

{ =========================================================================
  Сводные величины
  ========================================================================= }

function ragdoll_com(const rd: TRagdoll): TVec3;
var
  i: Integer;
  m, total: Single;
  c: TVec3;
begin
  c := v3_zero;
  total := 0;
  for i := 0 to rd.nparts - 1 do
  begin
    m := rd.part[i].massFrac;
    c := v3_add(c, v3_mul(g_bodies[rd.part[i].body].pos, m));
    total := total + m;
  end;
  if total > EPS then c := v3_mul(c, 1.0 / total);
  Result := c;
end;

function ragdoll_com_vel(const rd: TRagdoll): TVec3;
var
  i: Integer;
  m, total: Single;
  c: TVec3;
begin
  c := v3_zero;
  total := 0;
  for i := 0 to rd.nparts - 1 do
  begin
    m := rd.part[i].massFrac;
    c := v3_add(c, v3_mul(g_bodies[rd.part[i].body].linvel, m));
    total := total + m;
  end;
  if total > EPS then c := v3_mul(c, 1.0 / total);
  Result := c;
end;

function ragdoll_body_of_bone(const rd: TRagdoll; bone: Integer): Integer;
begin
  if (bone < 0) or (bone >= SK_MAX_BONES) or (rd.boneToPart[bone] < 0) then
    Result := -1
  else
    Result := rd.part[rd.boneToPart[bone]].body;
end;

function is_our_body(const rd: TRagdoll; body: Integer): Boolean;
var i: Integer;
begin
  for i := 0 to rd.nparts - 1 do
    if rd.part[i].body = body then
    begin
      Result := True;
      Exit;
    end;
  Result := False;
end;

function ragdoll_impact(const rd: TRagdoll; out point, dir: TVec3): Single;
var
  i, k: Integer;
  mf: ^TManifold;
  imp, best: Single;
begin
  Result := 0;
  best := 0;
  point := v3_zero;
  dir := v3_zero;
  for i := 0 to g_nmanifolds - 1 do
  begin
    mf := @g_manifolds[i];
    if not mf^.alive then Continue;
    if not (is_our_body(rd, mf^.a) or is_our_body(rd, mf^.b)) then Continue;
    imp := 0;
    for k := 0 to mf^.npoints - 1 do
      imp := imp + Abs(mf^.pt[k].normalImpulse);
    Result := Result + imp;
    if (imp > best) and (mf^.npoints > 0) then
    begin
      best := imp;
      point := v3_add(g_bodies[mf^.a].pos, mf^.pt[0].rA);
      dir := mf^.normal;
      if is_our_body(rd, mf^.a) then dir := v3_neg(dir);
    end;
  end;
end;

procedure ragdoll_add_impulse(var rd: TRagdoll; bone: Integer;
                              const imp: TVec3);
var b: Integer;
begin
  b := ragdoll_body_of_bone(rd, bone);
  if b < 0 then Exit;
  phys_apply_impulse(b, imp, g_bodies[b].pos);
end;

end.
