{ ============================================================================
  ubehave.pas  --  процедурные реакции тела, в духе Euphoria

  Идея, на которой держится Euphoria от NaturalMotion: персонаж не
  проигрывает заготовленную анимацию падения, а каждый кадр РЕШАЕТ, что
  делать, исходя из текущего состояния физики. Мышцы -- это моторы
  суставов, поведение -- это то, какую позу моторам подсунуть и с какой
  силой её держать.

  Здесь реализованы базовые рефлексы:

    * МЫШЕЧНЫЙ ТОНУС. Поза из анимации отрабатывается моторами с конечной
      силой. Удар сбивает тонус (оглушение), он восстанавливается за
      несколько десятых секунды -- отсюда естественная "ватность" после
      попадания.
    * РАВНОВЕСИЕ. Считается точка захвата (capture point) -- куда уедет
      центр масс, если ничего не делать. Пока ошибка мала, работает
      голеностоп, дальше подключается корпус.
    * ШАГ. Когда точка захвата ушла за пределы опоры, тело переставляет
      ногу под неё. Это то самое "спотыкание", ради которого Euphoria и
      затевалась.
    * ЗАЩИТА. Луч вперёд по скорости центра масс предсказывает удар.
      Если до него меньше времени реакции -- руки идут навстречу
      препятствию, чтобы смягчить падение.
    * ГРУППИРОВКА. В полёте шея прижимает голову, руки подтягиваются.
    * МЕЛЬНИЦА. В свободном полёте руки вращаются против закрутки тела,
      гася её -- так делают и кошки, и люди.

  Ничего из этого не является анимацией: всё считается от состояния мира.
  ============================================================================ }
unit ubehave;

{$MODE OBJFPC}
{$H+}

interface

uses
  SysUtils, Math, umath, ugjk, uphysics, uskel, uragdoll;

type
  TBehaveFlag = (BH_TONE,      { держать позу мышцами }
                 BH_BALANCE,   { голеностоп + корпус }
                 BH_STEP,      { переставлять ноги }
                 BH_PROTECT,   { выставлять руки на удар }
                 BH_TUCK,      { группироваться в полёте }
                 BH_WINDMILL); { гасить закрутку руками }
  TBehaveFlags = set of TBehaveFlag;

  TBehaveParams = record
    flags        : TBehaveFlags;
    tone         : Single;   { базовый тонус 0..1 }
    reaction     : Single;   { время реакции, с }
    stepThresh   : Single;   { при каком выносе точки захвата делать шаг, м }
    balanceGain  : Single;   { kp модели маятника, должен быть > 1 }
    copDamp      : Single;   { kd: вклад скорости ЦМ, с }
    copLimit     : Single;   { насколько далеко центр давления уходит, м }
    hipGain      : Single;   { усиление корпуса }
    recovery     : Single;   { скорость восстановления после оглушения, 1/с }
  end;

  TBehaveState = record
    com, comVel  : TVec3;
    capture      : TVec3;    { точка захвата, горизонталь }
    support      : TVec3;    { центр опоры }
    balanceErr   : TVec3;
    balanceMag   : Single;
    grounded     : Boolean;
    footContacts : Integer;
    airTime      : Single;
    stun         : Single;   { 0 -- бодр, 1 -- полностью оглушён }
    effTone      : Single;
    impact       : Single;   { импульс удара за прошлый шаг }
    impactDir    : TVec3;
    predictHit   : Boolean;
    predictPoint : TVec3;
    predictTime  : Single;
    stepLeg      : Integer;  { 0 нет, 1 левая, 2 правая }
    stepTimer    : Single;
    stepTarget   : TVec3;
    { человекочитаемое имя текущего поведения -- для отладки и титров }
    action       : string[31];
  end;

procedure behave_defaults(out prm: TBehaveParams);
procedure behave_init(out st: TBehaveState);

{ Главная процедура. Берёт желаемую позу (из анимации), состояние мира,
  и выдаёт позу, которую реально скармливает мышцам. }
procedure behave_update(var rd: TRagdoll; var st: TBehaveState;
                        const prm: TBehaveParams;
                        const animPose: TSkelPose; var outPose: TSkelPose;
                        dt: Single);

implementation

procedure behave_defaults(out prm: TBehaveParams);
begin
  prm.flags := [BH_TONE, BH_BALANCE, BH_STEP, BH_PROTECT, BH_TUCK, BH_WINDMILL];
  prm.tone := 1.0;
  prm.reaction := 0.25;
  prm.stepThresh := 0.11;
  prm.balanceGain := 1.7;
  prm.copDamp := 0.6;
  prm.copLimit := 0.085;
  prm.hipGain := 0.4;
  prm.recovery := 1.6;
end;

procedure behave_init(out st: TBehaveState);
begin
  FillChar(st, SizeOf(TBehaveState), 0);
  st.effTone := 1.0;
  st.action := 'стоит';
end;

{ ------------------------------------------------------------------
  Опора: ищем контакты стоп с чем-то, что не является частью тела.
  ------------------------------------------------------------------ }
procedure measure_support(const rd: TRagdoll; var st: TBehaveState);
var
  i, k, fl, fr, other: Integer;
  mf: ^TManifold;
  sum: TVec3;
  n: Integer;
  isA: Boolean;
begin
  fl := ragdoll_body_of_bone(rd, rd.bFootL);
  fr := ragdoll_body_of_bone(rd, rd.bFootR);
  sum := v3_zero;
  n := 0;

  for i := 0 to g_nmanifolds - 1 do
  begin
    mf := @g_manifolds[i];
    if (not mf^.alive) or (mf^.npoints = 0) then Continue;
    isA := (mf^.a = fl) or (mf^.a = fr);
    if not (isA or (mf^.b = fl) or (mf^.b = fr)) then Continue;
    { второй участник не должен быть частью того же тела }
    if isA then other := mf^.b else other := mf^.a;
    if (other = fl) or (other = fr) then Continue;

    for k := 0 to mf^.npoints - 1 do
    begin
      if isA then
        sum := v3_add(sum, v3_add(g_bodies[mf^.a].pos, mf^.pt[k].rA))
      else
        sum := v3_add(sum, v3_add(g_bodies[mf^.b].pos, mf^.pt[k].rB));
      Inc(n);
    end;
  end;

  st.footContacts := n;
  st.grounded := n > 0;
  { Центром опоры считаем середину между стопами, а не центр пятна
    контакта: пятно само смещается от нашего же управляющего момента,
    и обратная связь по нему раскачивается. }
  if (fl >= 0) and (fr >= 0) then
    st.support := v3_mul(v3_add(g_bodies[fl].pos, g_bodies[fr].pos), 0.5)
  else
    st.support := st.com;
  if n > 0 then st.support.y := v3_mul(sum, 1.0 / n).y;
end;

{ Голеностоп: сустав и кость стопы по номеру ноги (0 -- левая). }
function ankle_bone(const rd: TRagdoll; leg: Integer): Integer; inline;
begin
  if leg = 0 then Result := rd.bFootL else Result := rd.bFootR;
end;

function ankle_joint(const rd: TRagdoll; leg: Integer): Integer;
var i, bone: Integer;
begin
  bone := ankle_bone(rd, leg);
  for i := 0 to rd.njoints - 1 do
    if rd.joint[i].bone = bone then
    begin
      Result := i;
      Exit;
    end;
  Result := -1;
end;

{ Локальный поворот кости, дающий заданную мировую ориентацию.
  Родитель берётся из физики -- то есть из того, где тело реально сейчас. }
function local_for_world(const rd: TRagdoll; bone: Integer;
                         const qWorld: TQuat): TQuat;
var
  par, pp: Integer;
begin
  par := rd.skel.bone[bone].parent;
  pp := -1;
  while par >= 0 do
  begin
    if rd.boneToPart[par] >= 0 then
    begin
      pp := rd.boneToPart[par];
      Break;
    end;
    par := rd.skel.bone[par].parent;
  end;
  if pp < 0 then
    Result := qWorld
  else
    Result := q_mul(q_conj(ragdoll_part_world(rd, pp).rot), qWorld);
end;

{ Доворот локальной цели кости на заданный мировой поворот. }
procedure bias_bone(var p: TSkelPose; const rd: TRagdoll; bone: Integer;
                    const axisWorld: TVec3; angle: Single);
var
  parRot: TQuat;
  par, pp: Integer;
  axLocal: TVec3;
begin
  if (bone < 0) or (bone >= p.n) then Exit;
  if Abs(angle) < 1.0e-5 then Exit;

  par := rd.skel.bone[bone].parent;
  pp := -1;
  while par >= 0 do
  begin
    if rd.boneToPart[par] >= 0 then
    begin
      pp := rd.boneToPart[par];
      Break;
    end;
    par := rd.skel.bone[par].parent;
  end;
  if pp < 0 then parRot := q_identity
  else parRot := ragdoll_part_world(rd, pp).rot;

  { ось поворота переводим в систему родителя }
  axLocal := q_rotate(q_conj(parRot), axisWorld);
  p.local[bone].rot := q_norm(q_mul(q_from_axis(axLocal, angle),
                                    p.local[bone].rot));
end;

{ ------------------------------------------------------------------
  Главная процедура
  ------------------------------------------------------------------ }
procedure behave_update(var rd: TRagdoll; var st: TBehaveState;
                        const prm: TBehaveParams;
                        const animPose: TSkelPose; var outPose: TSkelPose;
                        dt: Single);
var
  g, comH, mag, k, fwdLen, side: Single;
  up, errDir, axis, vdir, toCapture: TVec3;
  hit: TRayHit;
  chest, headB: Integer;
  qUp: TQuat;
  swingBone, stanceBone, swingShin: Integer;
  i, nf, aj, ab: Integer;
  spin, r, tau, copTarget, evec: TVec3;
  qNow, qWant: TQuat;
  torsoB: Integer;
begin
  up := v3(0, 1, 0);
  g := 9.81;

  { ---------- 1. измерения ---------- }
  st.com := ragdoll_com(rd);
  st.comVel := ragdoll_com_vel(rd);
  measure_support(rd, st);

  comH := fmax(st.com.y - st.support.y, 0.15);
  { Точка захвата: куда придётся поставить ногу, чтобы погасить движение.
    Классическая оценка для перевёрнутого маятника. }
  k := Sqrt(comH / g);
  st.capture := v3(st.com.x + st.comVel.x * k, st.support.y,
                   st.com.z + st.comVel.z * k);

  st.balanceErr := v3(st.capture.x - st.support.x, 0,
                      st.capture.z - st.support.z);
  st.balanceMag := v3_len(st.balanceErr);

  if st.grounded then st.airTime := 0
  else st.airTime := st.airTime + dt;

  { ---------- 2. удары и оглушение ---------- }
  st.impact := ragdoll_impact(rd, st.predictPoint, st.impactDir);
  if st.impact > rd.totalMass * 0.9 then
    st.stun := fmin(1.0, st.stun + (st.impact / (rd.totalMass * 6.0)));
  st.stun := fmax(0, st.stun - prm.recovery * dt * 0.35);

  st.effTone := fclamp(prm.tone * (1.0 - st.stun), 0, 1);
  if not (BH_TONE in prm.flags) then st.effTone := 0;

  { ---------- 3. базовая цель -- поза из анимации ---------- }
  pose_copy(animPose, outPose);
  st.action := 'стоит';

  { ---------- 4. равновесие ----------
    Линейная модель перевёрнутого маятника: ускорение центра масс равно
    (g/h) * (ЦМ - центр давления). Значит, управлять надо не силой, а
    ПОЛОЖЕНИЕМ ЦЕНТРА ДАВЛЕНИЯ под стопой:

        p = kp * смещение_ЦМ + kd * скорость_ЦМ,   kp > 1

    Такой выбор делает систему устойчивой. Центр давления физически не
    может выйти за стопу -- отсюда и предел возможностей голеностопа, и
    момент, когда приходится делать шаг. Момент в голеностопе, который
    ставит давление в точку p, равен (p - голеностоп) x (m g вверх). }
  if (BH_BALANCE in prm.flags) and st.grounded and (st.effTone > 0.05) then
  begin
    errDir := v3(st.com.x - st.support.x, 0, st.com.z - st.support.z);

    copTarget := v3_add(v3_mul(errDir, prm.balanceGain),
                        v3_mul(v3(st.comVel.x, 0, st.comVel.z), prm.copDamp));

    { центр давления обязан остаться внутри стопы }
    mag := v3_len(copTarget);
    if mag > prm.copLimit then copTarget := v3_mul(copTarget, prm.copLimit / mag);

    nf := 0;
    for i := 0 to 1 do
      if ankle_joint(rd, i) >= 0 then Inc(nf);

    if nf > 0 then
      for i := 0 to 1 do
      begin
        aj := ankle_joint(rd, i);
        if aj < 0 then Continue;
        ab := ragdoll_body_of_bone(rd, ankle_bone(rd, i));
        if ab < 0 then Continue;

        { плечо от голеностопа до желаемой точки давления }
        r := v3_add(st.support, copTarget);
        r := v3(r.x - g_bodies[ab].pos.x, 0, r.z - g_bodies[ab].pos.z);
        tau := v3_cross(r, v3(0, rd.totalMass * 9.81 / nf, 0));

        mag := v3_len(tau);
        k := rd.joint[aj].baseTorque * st.effTone;
        if mag > k then tau := v3_mul(tau, k / mag);
        { Момент идёт упреждением внутрь мотора: приложенный снаружи,
          он был бы тут же съеден самим мотором. }
        phys_joint_set_bias_torque(rd.joint[aj].joint, v3_neg(tau));
      end;

    if v3_len(errDir) > 0.03 then st.action := 'ловит равновесие';

  end;

  { ---------- 4б. корпус держим вертикально ----------
    Поза задаёт углы ОТНОСИТЕЛЬНО родителя, поэтому наклон таза корпус не
    видит и заваливается вместе с ним. Приём из SIMBICON: верхнюю часть
    тела стабилизируют в МИРОВОЙ системе, а реакция уходит через таз в
    ноги -- это и есть тазобедренная стратегия равновесия. }
  if (BH_BALANCE in prm.flags) and (st.effTone > 0.05) and
     (rd.boneToPart[rd.bChest] >= 0) then
  begin
    torsoB := ragdoll_body_of_bone(rd, rd.bChest);
    qNow := ragdoll_part_world(rd, rd.boneToPart[rd.bChest]).rot;
    { желаемая ориентация: та же, но ось кости строго вверх }
    qWant := q_mul(q_from_to(q_rotate(qNow, rd.skel.bone[rd.bChest].dirLocal),
                             up), qNow);
    evec := q_to_rotvec(q_mul(qWant, q_conj(qNow)));
    tau := v3_sub(v3_mul(evec, prm.hipGain * 260.0),
                  v3_mul(g_bodies[torsoB].angvel, prm.hipGain * 55.0));
    mag := v3_len(tau);
    if mag > 300.0 * st.effTone then tau := v3_mul(tau, 300.0 * st.effTone / mag);

    { Знак: упреждение идёт ребёнку сустава со знаком "+", а ребёнок
      здесь -- как раз корпус. }
    for i := 0 to rd.njoints - 1 do
      if rd.joint[i].bone = rd.bSpine then
        phys_joint_set_bias_torque(rd.joint[i].joint, tau);
  end;

  { ---------- 5. шаг ---------- }
  if (BH_STEP in prm.flags) and st.grounded then
  begin
    if st.stepTimer > 0 then
    begin
      st.stepTimer := st.stepTimer - dt;
      if st.stepTimer <= 0 then st.stepLeg := 0;
    end;

    if (st.stepLeg = 0) and (st.balanceMag > prm.stepThresh) then
    begin
      { шагаем той ногой, что дальше от точки захвата }
      if v3_distsq(g_bodies[ragdoll_body_of_bone(rd, rd.bFootL)].pos, st.capture) >
         v3_distsq(g_bodies[ragdoll_body_of_bone(rd, rd.bFootR)].pos, st.capture) then
        st.stepLeg := 1
      else
        st.stepLeg := 2;
      st.stepTimer := 0.42;
      st.stepTarget := st.capture;
    end;

    if st.stepLeg <> 0 then
    begin
      if st.stepLeg = 1 then
      begin
        swingBone := rd.bThighL;
        swingShin := rd.bShinL;
        stanceBone := rd.bThighR;
      end
      else
      begin
        swingBone := rd.bThighR;
        swingShin := rd.bShinR;
        stanceBone := rd.bThighL;
      end;

      toCapture := v3_sub(st.stepTarget,
                          g_bodies[ragdoll_body_of_bone(rd, swingBone)].pos);
      toCapture.y := 0;
      fwdLen := v3_len(toCapture);
      if fwdLen > 1.0e-4 then
      begin
        vdir := v3_mul(toCapture, 1.0 / fwdLen);
        axis := v3_cross(up, vdir);
        { маховая нога идёт вперёд, опорная слегка подгибается }
        k := fclamp(fwdLen * 1.6, 0, 1.1);
        bias_bone(outPose, rd, swingBone, axis, -k);
        bias_bone(outPose, rd, swingShin, axis, k * 0.5);
        bias_bone(outPose, rd, stanceBone, axis, k * 0.15);
      end;
      st.action := 'делает шаг';
    end;
  end;

  { ---------- 6. защита руками ---------- }
  st.predictHit := False;
  if BH_PROTECT in prm.flags then
  begin
    chest := ragdoll_body_of_bone(rd, rd.bChest);
    mag := v3_len(st.comVel);
    if (chest >= 0) and (mag > 1.2) then
    begin
      vdir := v3_mul(st.comVel, 1.0 / mag);
      hit := phys_raycast(g_bodies[chest].pos, vdir, mag * prm.reaction * 2.0);
      if hit.hit and (hit.body <> chest) then
      begin
        st.predictTime := hit.distance / mag;
        st.predictHit := st.predictTime < prm.reaction * 2.0;
        st.predictPoint := hit.point;
      end;
    end;

    if st.predictHit and (st.effTone > 0.05) then
    begin
      { руки навстречу препятствию: плечи вперёд, локти чуть согнуты }
      vdir := v3_norm(v3_sub(st.predictPoint, g_bodies[chest].pos));
      axis := v3_cross(v3_norm(q_rotate(ragdoll_part_world(rd,
                               rd.boneToPart[rd.bChest]).rot, v3(1, 0, 0))), vdir);
      if v3_lensq(axis) < 1.0e-6 then axis := v3(0, 0, 1);
      axis := v3_norm(axis);
      k := fclamp(1.2 - st.predictTime * 2.0, 0.2, 1.3);
      bias_bone(outPose, rd, rd.bArmL, axis, k);
      bias_bone(outPose, rd, rd.bArmR, axis, k);
      bias_bone(outPose, rd, rd.bForeL, axis, -k * 0.5);
      bias_bone(outPose, rd, rd.bForeR, axis, -k * 0.5);
      { руки напрягаем сильнее остального тела }
      ragdoll_set_chain_tone(rd, rd.bArmL, fmin(1.0, st.effTone + 0.3));
      ragdoll_set_chain_tone(rd, rd.bArmR, fmin(1.0, st.effTone + 0.3));
      st.action := 'выставляет руки';
    end;
  end;

  { ---------- 7. группировка и мельница в полёте ---------- }
  if (st.airTime > 0.12) and (st.effTone > 0.05) then
  begin
    if BH_TUCK in prm.flags then
    begin
      { голову прижать: шея доворачивается к груди }
      headB := rd.boneToPart[rd.bChest];
      if headB >= 0 then
      begin
        qUp := ragdoll_part_world(rd, headB).rot;
        axis := v3_norm(q_rotate(qUp, v3(1, 0, 0)));
        bias_bone(outPose, rd, rd.bHead, axis, 0.5);
      end;
      bias_bone(outPose, rd, rd.bForeL, v3(0, 0, 1), 0.6);
      bias_bone(outPose, rd, rd.bForeR, v3(0, 0, 1), -0.6);
      st.action := 'группируется';
    end;

    if BH_WINDMILL in prm.flags then
    begin
      { гасим закрутку корпуса противовращением рук }
      i := ragdoll_body_of_bone(rd, rd.bChest);
      if i >= 0 then
      begin
        spin := g_bodies[i].angvel;
        mag := v3_len(spin);
        if mag > 0.8 then
        begin
          axis := v3_mul(spin, 1.0 / mag);
          k := fclamp(mag * 0.25, 0, 1.0);
          bias_bone(outPose, rd, rd.bArmL, axis, -k);
          bias_bone(outPose, rd, rd.bArmR, axis, k);
        end;
      end;
    end;
  end;

  { ---------- 8. отдать мышцам ---------- }
  side := st.effTone;
  if st.airTime > 0.3 then side := side * 0.75;   { в полёте тело мягче }
  ragdoll_set_tone(rd, side);
  ragdoll_drive_pose(rd, outPose);

  if st.stun > 0.3 then st.action := 'оглушён';
  if (not st.grounded) and (st.airTime > 0.2) then
    if st.action = 'стоит' then st.action := 'в воздухе';
end;

end.
