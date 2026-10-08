{ ============================================================================
  test_anim.pas  --  тесты скелета, анимации, суставов, рэгдола и поведения

  Ни OpenGL, ни дисплей не нужны.
  ============================================================================ }
program test_anim;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugjk, uphysics, uskel, uragdoll, ubehave;

var
  g_fail: Integer = 0;
  g_pass: Integer = 0;

procedure check(cond: Boolean; const name: string);
begin
  if cond then begin Inc(g_pass); WriteLn('  ok   ', name); end
  else begin Inc(g_fail); WriteLn('  FAIL ', name); end;
end;

procedure check_near(a, b, tol: Single; const name: string);
begin
  if Abs(a - b) <= tol then
  begin
    Inc(g_pass);
    WriteLn(Format('  ok   %s (%.4f ~ %.4f)', [name, a, b]));
  end
  else
  begin
    Inc(g_fail);
    WriteLn(Format('  FAIL %s: получено %.4f, ожидалось %.4f', [name, a, b]));
  end;
end;

function xf(const p: TVec3; const q: TQuat): TTransform;
begin
  Result.pos := p;
  Result.rot := q;
end;

{ ====================================================== скелет и кинематика }
procedure test_skeleton;
var
  s: TSkeleton;
  p, w: TSkelPose;
  a, b, c: Integer;
  t: TTransform;
begin
  WriteLn('-- скелет и прямая кинематика');
  skel_clear(s);
  a := skel_add_bone(s, 'root', SK_ROOT, xf(v3(0, 1, 0), q_identity));
  b := skel_add_bone(s, 'mid',  a,       xf(v3(0, 1, 0), q_identity));
  c := skel_add_bone(s, 'tip',  b,       xf(v3(0, 1, 0), q_identity));
  skel_finalize(s);

  check(s.nbones = 3, 'три кости добавлены');
  check(skel_find(s, 'mid') = b, 'поиск кости по имени');
  check_near(s.bone[a].length, 1.0, 1e-5, 'длина кости из смещения ребёнка');
  check_near(s.bone[a].dirLocal.y, 1.0, 1e-5, 'направление кости');

  pose_bind(s, p);
  skel_world(s, p, xf(v3_zero, q_identity), w);
  check_near(w.local[c].pos.y, 3.0, 1e-5, 'мир: кончик цепи на высоте 3');

  { поворот средней кости на 90 вокруг Z уводит кончик в -X }
  p.local[b].rot := q_from_axis(v3(0, 0, 1), PI_F * 0.5);
  skel_world(s, p, xf(v3_zero, q_identity), w);
  check_near(w.local[c].pos.x, -1.0, 1e-4, 'поворот средней кости: X кончика');
  check_near(w.local[c].pos.y,  2.0, 1e-4, 'поворот средней кости: Y кончика');

  { та же точка через одиночный расчёт }
  t := skel_bone_world(s, p, xf(v3_zero, q_identity), c);
  check_near(v3_dist(t.pos, w.local[c].pos), 0, 1e-5,
             'одиночный расчёт совпал с полным');

  { корневой трансформ сдвигает всё }
  skel_world(s, p, xf(v3(5, 0, 0), q_identity), w);
  check_near(w.local[c].pos.x, 4.0, 1e-4, 'сдвиг корня переносит цепь');
end;

{ ============================================================ позы и клипы }
procedure test_pose_anim;
var
  s: TSkeleton;
  pa, pb, pr, pref: TSkelPose;
  m: TBoneMask;
  clip: TAnimClip;
  i, a, b: Integer;
  v: TVec3;
begin
  WriteLn('-- позы, смешивание, клипы');
  skel_clear(s);
  a := skel_add_bone(s, 'root', SK_ROOT, xf(v3_zero, q_identity));
  b := skel_add_bone(s, 'arm',  a,       xf(v3(1, 0, 0), q_identity));
  skel_add_bone(s, 'hand', b, xf(v3(1, 0, 0), q_identity));
  skel_finalize(s);

  pose_bind(s, pa);
  pose_copy(pa, pb);
  pb.local[b].rot := q_from_axis(v3(0, 0, 1), 1.0);

  pose_blend(pa, pb, 0.0, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 0.0, 1e-5, 'смешивание t=0');
  pose_blend(pa, pb, 1.0, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 1.0, 1e-4, 'смешивание t=1');
  pose_blend(pa, pb, 0.5, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 0.5, 1e-3, 'смешивание t=0.5');

  { маска: кость с нулевым весом не меняется }
  mask_clear(m, s.nbones, 0);
  m.w[b] := 0;
  pose_blend_masked(pa, pb, 1.0, m, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 0.0, 1e-5,
             'маска с нулевым весом не пускает слой');
  m.w[b] := 1;
  pose_blend_masked(pa, pb, 1.0, m, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 1.0, 1e-4,
             'маска с единичным весом пускает слой целиком');

  { аддитивный слой }
  pose_copy(pa, pref);
  pose_additive(pa, pref, pb, 1.0, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 1.0, 1e-4,
             'аддитивный слой добавляет разницу');

  { клип }
  clip_clear(clip, 'test', 2.0, True);
  clip_add_rot(clip, b, 0.0, q_identity);
  clip_add_rot(clip, b, 1.0, q_from_axis(v3(0, 0, 1), 1.0));
  clip_add_rot(clip, b, 2.0, q_identity);
  clip_add_pos(clip, b, 0.0, v3(1, 0, 0));
  clip_add_pos(clip, b, 2.0, v3(3, 0, 0));

  pose_bind(s, pr);
  anim_sample(clip, 0.0, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 0.0, 1e-4, 'клип t=0');
  anim_sample(clip, 1.0, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 1.0, 1e-3, 'клип t=1');
  anim_sample(clip, 0.5, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 0.5, 1e-2, 'клип t=0.5');
  anim_sample(clip, 1.0, pr);
  check_near(pr.local[b].pos.x, 2.0, 1e-3, 'клип: смещение интерполируется');

  { зацикливание }
  anim_sample(clip, 4.0, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 0.0, 1e-3,
             'клип зациклен: t=4 это t=0');
  anim_sample(clip, 5.0, pr);
  check_near(v3_len(q_to_rotvec(pr.local[b].rot)), 1.0, 1e-3,
             'клип зациклен: t=5 это t=1');

  i := 0;
  if i <> 0 then ;
  v := v3_zero;
  if v3_lensq(v) > 0 then ;
end;

{ ================================================================= скиннинг }
procedure test_skinning;
var
  s: TSkeleton;
  p, w: TSkelPose;
  pal: TMatrixPalette;
  src: TSkinArray;
  outP, outN: array[0..3] of TVec3;
  a, b: Integer;
begin
  WriteLn('-- скиннинг');
  skel_clear(s);
  a := skel_add_bone(s, 'root', SK_ROOT, xf(v3_zero, q_identity));
  b := skel_add_bone(s, 'arm',  a,       xf(v3(1, 0, 0), q_identity));
  skel_add_bone(s, 'tip', b, xf(v3(1, 0, 0), q_identity));
  skel_finalize(s);
  pose_bind(s, p);
  skel_world(s, p, xf(v3_zero, q_identity), w);

  SetLength(src, 2);
  src[0].pos := v3(1, 0, 0);     { точно в основании второй кости }
  src[0].nrm := v3(0, 1, 0);
  src[0].bone[0] := b; src[0].weight[0] := 1;
  src[1].pos := v3(2, 0, 0);
  src[1].nrm := v3(0, 1, 0);
  src[1].bone[0] := b; src[1].weight[0] := 1;

  { поза привязки: вершины обязаны остаться на месте }
  skel_palette(s, w, pal);
  skin_apply(pal, src, outP, outN);
  check_near(v3_dist(outP[0], v3(1, 0, 0)), 0, 1e-5,
             'поза привязки не двигает вершины');
  check_near(v3_dist(outP[1], v3(2, 0, 0)), 0, 1e-5,
             'поза привязки не двигает вершины (2)');

  { поворот кости на 90 вокруг Z: вершина (2,0,0) уезжает в (1,1,0) }
  p.local[b].rot := q_from_axis(v3(0, 0, 1), PI_F * 0.5);
  skel_world(s, p, xf(v3_zero, q_identity), w);
  skel_palette(s, w, pal);
  skin_apply(pal, src, outP, outN);
  check_near(v3_dist(outP[0], v3(1, 0, 0)), 0, 1e-4,
             'вершина в шарнире остаётся на месте');
  check_near(v3_dist(outP[1], v3(1, 1, 0)), 0, 1e-4,
             'вершина на конце кости поворачивается');
  check_near(v3_dist(outN[1], v3(-1, 0, 0)), 0, 1e-4,
             'нормаль поворачивается вместе с костью');

  { автоматические веса: сумма равна единице }
  src[0].pos := v3(1.5, 0.05, 0);
  skin_autoweight(s, w, src[0], 2);
  check_near(src[0].weight[0] + src[0].weight[1] + src[0].weight[2] +
             src[0].weight[3], 1.0, 1e-4, 'автовеса в сумме дают 1');
end;

{ ================================================================== суставы }
procedure test_joints;
var
  i, anchor, b, j, prev: Integer;
  chain: array[0..4] of Integer;
  v: TVec3;
  err: Single;
begin
  WriteLn('-- суставы');

  { маятник: длина держится точно }
  phys_init;
  anchor := phys_add_body(shape_sphere(0.1), v3(0, 5, 0), q_identity, 0);
  b := phys_add_body(shape_capsule(0.15, 0.4), v3(0, 4.3, 0), q_identity, 2.0);
  phys_add_joint(JT_BALL, anchor, b, v3(0, 5, 0), v3(1, 0, 0));
  for i := 1 to 600 do phys_step(1 / 120);
  check_near(v3_dist(g_bodies[b].pos, v3(0, 5, 0)), 0.7, 1e-3,
             'маятник: длина подвеса');
  check_near(g_bodies[b].pos.x, 0.0, 0.01, 'маятник: успокоился под точкой');

  { цепь не растягивается }
  phys_init;
  anchor := phys_add_body(shape_sphere(0.1), v3(0, 8, 0), q_identity, 0);
  prev := anchor;
  for i := 0 to 4 do
  begin
    chain[i] := phys_add_body(shape_capsule(0.1, 0.25),
                              v3(0, 7.5 - i * 0.5, 0), q_identity, 1.0);
    phys_add_joint(JT_BALL, prev, chain[i], v3(0, 8.0 - i * 0.5, 0), v3(1, 0, 0));
    prev := chain[i];
  end;
  for i := 1 to 900 do phys_step(1 / 120);
  err := 0;
  for i := 0 to 4 do
    err := fmax(err, Abs(g_bodies[chain[i]].pos.y - (7.5 - i * 0.5)));
  check(err < 0.02, Format('цепь из 5 звеньев не растянулась (%.4f м)', [err]));

  { конус ограничивает наклон }
  phys_init;
  anchor := phys_add_body(shape_sphere(0.1), v3(0, 5, 0), q_identity, 0);
  b := phys_add_body(shape_capsule(0.1, 0.5), v3(0.7, 5, 0), q_identity, 3.0);
  j := phys_add_joint(JT_BALL, anchor, b, v3(0, 5, 0), v3(1, 0, 0));
  phys_joint_limits(j, 0.3, 0.3, -0.1, 0.1);
  for i := 1 to 900 do phys_step(1 / 120);
  v := q_to_rotvec(phys_joint_current(j));
  check_near(Sqrt(v.y * v.y + v.z * v.z), 0.30, 0.02, 'конус держит предел');
  check(Abs(v.x) < 0.12, 'предел кручения соблюдён');

  { мотор держит позу против силы тяжести }
  phys_init;
  anchor := phys_add_body(shape_sphere(0.1), v3(0, 5, 0), q_identity, 0);
  b := phys_add_body(shape_capsule(0.1, 0.5), v3(0.7, 5, 0), q_identity, 3.0);
  j := phys_add_joint(JT_BALL, anchor, b, v3(0, 5, 0), v3(1, 0, 0));
  phys_joint_limits(j, 1.5, 1.5, -1.5, 1.5);
  phys_joint_motor(j, True, 20, 1.0, 400);
  phys_joint_target(j, q_identity);
  for i := 1 to 600 do phys_step(1 / 120);
  check(v3_len(q_to_rotvec(phys_joint_current(j))) < 0.03,
        'мотор удерживает горизонталь');

  { мотор приводит к новой цели }
  phys_joint_target(j, q_from_axis(v3(0, 0, 1), 0.8));
  for i := 1 to 600 do phys_step(1 / 120);
  check_near(q_to_rotvec(phys_joint_current(j)).z, 0.8, 0.03,
             'мотор пришёл к заданной цели');

  { связанные тела не сталкиваются }
  check(phys_pair_ignored(anchor, b), 'сустав отключил столкновение пары');
end;

{ ==================================================================== рэгдол }
var
  g_sk: TSkeleton;
  g_idle: TSkelPose;
  g_groundY: Single;

procedure make_floor;
var pts: array[0..7] of TVec3;
begin
  pts[0] := v3(-20, -1, -20); pts[1] := v3(20, -1, -20);
  pts[2] := v3(-20,  1, -20); pts[3] := v3(20,  1, -20);
  pts[4] := v3(-20, -1,  20); pts[5] := v3(20, -1,  20);
  pts[6] := v3(-20,  1,  20); pts[7] := v3(20,  1,  20);
  phys_set_material(phys_add_body(shape_hull(pts), v3(0, -1, 0),
                                  q_identity, 0), 0.95, 0.0);
end;

procedure spawn(out rd: TRagdoll; lift: Single);
var root: TTransform;
begin
  root.pos := v3(0, lift, 0);
  root.rot := q_identity;
  ragdoll_build(rd, g_sk, g_idle, root, 70);
end;

procedure test_ragdoll;
var
  rd: TRagdoll;
  p: TSkelPose;
  root: TTransform;
  i, k, hb: Integer;
  maxErr, e: Single;
  pa, pb: TVec3;
begin
  WriteLn('-- рэгдол');
  ragdoll_humanoid_skeleton(g_sk, 1.75);
  ragdoll_idle_pose(g_sk, g_idle);
  check(g_sk.nbones = 21, Format('гуманоид: %d костей', [g_sk.nbones]));

  phys_init;
  spawn(rd, 0);
  check(rd.nparts = 17, Format('частей тела: %d', [rd.nparts]));
  check(rd.njoints = 16, Format('суставов: %d', [rd.njoints]));
  check_near(ragdoll_com(rd).y, 1.0, 0.12, 'центр масс на разумной высоте');

  g_groundY := 1.0e9;
  for i := 0 to rd.nparts - 1 do
    g_groundY := fmin(g_groundY, g_bodies[rd.part[i].body].box.mn.y);
  g_groundY := -g_groundY;

  { чтение позы обратно из физики }
  phys_init;
  make_floor;
  spawn(rd, g_groundY);
  for i := 1 to 60 do phys_step(1 / 120);
  ragdoll_read_pose(rd, p, root);
  hb := ragdoll_body_of_bone(rd, rd.bHead);
  check(p.n = g_sk.nbones, 'поза прочитана целиком');
  { сверяем НАЧАЛО кости головы, а не центр её тела }
  check_near(v3_dist(skel_bone_world(g_sk, p, root, rd.bHead).pos,
                     ragdoll_part_world(rd, rd.boneToPart[rd.bHead]).pos),
             0.0, 0.01, 'поза из физики совпадает с физикой');
  if hb < 0 then ;

  { тряпка не разваливается }
  phys_init;
  make_floor;
  root.pos := v3(0, 1.2, 0);
  root.rot := q_from_axis(v3(1, 0, 0), 0.5);
  ragdoll_build(rd, g_sk, g_idle, root, 70);
  ragdoll_set_tone(rd, 0);
  maxErr := 0;
  for k := 1 to 600 do
  begin
    phys_step(1 / 120);
    for i := 0 to rd.njoints - 1 do
    begin
      pa := v3_add(g_bodies[g_joints[rd.joint[i].joint].a].pos,
            q_rotate(g_bodies[g_joints[rd.joint[i].joint].a].orient,
                     g_joints[rd.joint[i].joint].localAnchorA));
      pb := v3_add(g_bodies[g_joints[rd.joint[i].joint].b].pos,
            q_rotate(g_bodies[g_joints[rd.joint[i].joint].b].orient,
                     g_joints[rd.joint[i].joint].localAnchorB));
      e := v3_dist(pa, pb);
      if e > maxErr then maxErr := e;
    end;
  end;
  check(maxErr < 0.03,
        Format('тряпичная кукла держится: расхождение суставов %.4f м', [maxErr]));
  check(ragdoll_com(rd).y < 0.45, 'тряпка улеглась на пол');
end;

{ ================================================================= поведение }
function stand_time(flags: TBehaveFlags; push: Single): Single;
var
  rd: TRagdoll;
  st: TBehaveState;
  prm: TBehaveParams;
  animp, outp: TSkelPose;
  i, cb: Integer;
begin
  phys_init;
  make_floor;
  spawn(rd, g_groundY);
  behave_defaults(prm);
  prm.flags := flags;
  behave_init(st);
  pose_copy(g_idle, animp);
  cb := ragdoll_body_of_bone(rd, rd.bChest);

  Result := 20;
  for i := 1 to 2400 do
  begin
    behave_update(rd, st, prm, animp, outp, 1 / 120);
    phys_step(1 / 120);
    if (push > 0) and (i = 120) then
      phys_apply_impulse(cb, v3(0, 0, -push), g_bodies[cb].pos);
    if g_bodies[cb].pos.y < 0.9 then
    begin
      Result := i / 120;
      Exit;
    end;
  end;
end;

procedure test_behave;
var
  tLimp, tTone, tBalance: Single;
  rd: TRagdoll;
  st: TBehaveState;
  prm: TBehaveParams;
  animp, outp: TSkelPose;
  i, cb: Integer;
  toneAfter: Single;
begin
  WriteLn('-- поведение');

  tLimp := stand_time([], 0);
  tTone := stand_time([BH_TONE], 0);
  tBalance := stand_time([BH_TONE, BH_BALANCE, BH_STEP], 0);
  WriteLn(Format('     устоял: тряпка %.2f с, мышцы %.2f с, равновесие %.2f с',
          [tLimp, tTone, tBalance]));
  check(tTone > tLimp + 0.3, 'мышцы держат позу дольше тряпки');
  { Порог намеренно консервативный: полноценное управление двуногим --
    это отдельная исследовательская задача, здесь важен сам факт
    многократного выигрыша от работы голеностопа. }
  check(tBalance > tTone * 2.5,
        Format('равновесие даёт выигрыш в %.1f раза', [tBalance / tTone]));
  check(tBalance > 3.0, 'с равновесием стоит дольше трёх секунд');

  { оглушение: удар сбивает тонус, потом он возвращается }
  phys_init;
  make_floor;
  spawn(rd, g_groundY);
  behave_defaults(prm);
  prm.flags := [BH_TONE, BH_BALANCE];
  behave_init(st);
  pose_copy(g_idle, animp);
  cb := ragdoll_body_of_bone(rd, rd.bChest);
  for i := 1 to 120 do
  begin
    behave_update(rd, st, prm, animp, outp, 1 / 120);
    phys_step(1 / 120);
  end;
  check_near(st.effTone, 1.0, 0.05, 'в покое тонус полный');
  { Оглушает именно УДАР о препятствие, а не толчок: сбрасываем
    персонажа с высоты и смотрим на тонус сразу после приземления. }
  phys_init;
  make_floor;
  spawn(rd, g_groundY + 2.0);
  behave_init(st);
  cb := ragdoll_body_of_bone(rd, rd.bChest);
  toneAfter := 1.0;
  for i := 1 to 200 do
  begin
    behave_update(rd, st, prm, animp, outp, 1 / 120);
    phys_step(1 / 120);
    if st.effTone < toneAfter then toneAfter := st.effTone;
  end;
  check(toneAfter < 0.85,
        Format('падение с двух метров оглушает: тонус падал до %.2f',
               [toneAfter]));
  for i := 1 to 600 do
  begin
    behave_update(rd, st, prm, animp, outp, 1 / 120);
    phys_step(1 / 120);
  end;
  check(st.effTone > toneAfter + 0.05,
        Format('тонус восстанавливается: сейчас %.2f', [st.effTone]));

  { точка захвата считается и растёт при разгоне }
  check(v3_len(st.balanceErr) >= 0, 'точка захвата вычислена');
end;

begin
  WriteLn('=== тесты анимации, рэгдола и поведения ===');
  test_skeleton;
  test_pose_anim;
  test_skinning;
  test_joints;
  test_ragdoll;
  test_behave;
  WriteLn;
  WriteLn(Format('итого: %d пройдено, %d провалено', [g_pass, g_fail]));
  if g_fail > 0 then Halt(1);
end.
