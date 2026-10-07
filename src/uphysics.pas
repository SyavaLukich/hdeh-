{ ============================================================================
  uphysics.pas  --  физический движок твёрдых тел

  Архитектура повторяет то, что делали в Quake 3 и в движках Pangea: один
  глобальный мир, плоские массивы фиксированного размера, никакой динамики
  во время шага симуляции.

  Конвейер одного шага:
    1. интегрирование сил            (симплектический Эйлер)
    2. широкая фаза                  (sweep and prune по оси X)
    3. узкая фаза                    (GJK + EPA из модуля ugjk)
    4. накопление устойчивых манифолдов (до 4 точек, с историей)
    5. решатель последовательных импульсов (с тёплым стартом)
    6. интегрирование положений и засыпание тел

  Всё считается в Single: современные процессоры обрабатывают 8 таких
  чисел за такт в AVX, а для игровой физики точности хватает с запасом.
  ============================================================================ }
unit uphysics;

{$MODE OBJFPC}
{$H+}
{$INLINE ON}
{$OPTIMIZATION LEVEL3}

interface

uses
  umath, ugjk;

const
  PHYS_MAX_BODIES    = 4096;
  PHYS_MAX_PAIRS     = 16384;
  PHYS_MAX_MANIFOLDS = 8192;
  PHYS_MAX_POINTS    = 4;       { точек в одном манифолде }

  { Настройки решателя. Значения подобраны для шага 1/120 с. }
  PHYS_VEL_ITERS     = 8;
  PHYS_POS_ITERS     = 3;
  PHYS_SLOP          = 0.005;   { допустимое проникновение, м }
  PHYS_BAUMGARTE     = 0.2;     { доля ошибки, исправляемая за шаг }
  PHYS_REST_THRESH   = 1.0;     { ниже этой скорости отскок не считается }
  PHYS_SLEEP_LIN     = 0.08;
  PHYS_SLEEP_ANG     = 0.10;
  PHYS_SLEEP_TIME    = 0.6;
  PHYS_CONTACT_TOL   = 0.02;    { радиус склейки точек манифолда }
  PHYS_MAX_CORRECT   = 0.2;     { ограничение на коррекцию за шаг, м }

type
  TBodyFlags = set of (BF_STATIC, BF_SLEEPING, BF_NOSLEEP, BF_ENABLED,
                       BF_LOCK_ROT);

  { Твёрдое тело. Хранится по значению в плоском массиве -- проход
    по телам линеен по памяти, префетчер процессора на этом отдыхает. }
  TBody = record
    pos        : TVec3;
    orient     : TQuat;
    linvel     : TVec3;
    angvel     : TVec3;
    force      : TVec3;
    torque     : TVec3;

    invMass    : Single;
    invIlocal  : TVec3;    { диагональ обратного тензора в локальных осях }
    invIworld  : TMat3;    { пересчитывается каждый шаг }

    friction   : Single;
    restitution: Single;
    linDamp    : Single;
    angDamp    : Single;

    shape      : Integer;  { индекс в таблице форм }
    flags      : TBodyFlags;
    sleepTimer : Single;
    box        : TAABB;
    userTag    : Integer;  { на что сослаться из игровой логики }
  end;
  PBody = ^TBody;

  { Одна точка контакта. Храним якоря в локальных координатах тел --
    это позволяет узнавать точку на следующем кадре и переносить
    накопленный импульс (тёплый старт). }
  TContactPoint = record
    localA, localB : TVec3;
    rA, rB         : TVec3;   { от центра масс к точке, мировые }
    normalImpulse  : Single;
    tangImpulse    : array[0..1] of Single;
    massNormal     : Single;
    massTang       : array[0..1] of Single;
    bias           : Single;
    penetration    : Single;
    relvel0        : Single;  { нормальная скорость до решателя (для отскока) }
    age            : Integer;
  end;

  TManifold = record
    a, b      : Integer;      { индексы тел }
    normal    : TVec3;        { из A в B }
    tangent   : array[0..1] of TVec3;
    npoints   : Integer;
    pt        : array[0..PHYS_MAX_POINTS - 1] of TContactPoint;
    friction  : Single;
    restitution: Single;
    alive     : Boolean;
  end;
  PManifold = ^TManifold;

  TRayHit = record
    hit     : Boolean;
    body    : Integer;
    point   : TVec3;
    normal  : TVec3;
    distance: Single;
  end;

var
  { Глобальное состояние мира -- в духе старых движков, без фабрик и
    синглтонов: просто модульные переменные. }
  g_bodies     : array[0..PHYS_MAX_BODIES - 1] of TBody;
  g_shapes     : array[0..PHYS_MAX_BODIES - 1] of TShape;
  g_nbodies    : Integer = 0;
  g_manifolds  : array[0..PHYS_MAX_MANIFOLDS - 1] of TManifold;
  g_nmanifolds : Integer = 0;
  g_gravity    : TVec3;
  g_phys_time  : Double = 0;

  { Счётчики для профилировки }
  g_stat_pairs    : Integer = 0;
  g_stat_contacts : Integer = 0;
  g_stat_awake    : Integer = 0;

procedure phys_init;
procedure phys_clear;

{ Создаёт тело. mass = 0 -> статическое. Возвращает индекс тела. }
function  phys_add_body(const s: TShape; const pos: TVec3; const q: TQuat;
                        mass: Single): Integer;
procedure phys_set_material(id: Integer; friction, restitution: Single);
procedure phys_apply_impulse(id: Integer; const imp, point: TVec3);
procedure phys_apply_force(id: Integer; const f: TVec3);
procedure phys_wake(id: Integer);
function  phys_pose(id: Integer): TPose; inline;

{ Один шаг симуляции фиксированной длины. }
procedure phys_step(dt: Single);

{ Трассировка луча по всему миру. }
function  phys_raycast(const ro, rd: TVec3; maxdist: Single): TRayHit;

implementation

{ =========================================================================
  Вспомогательные функции
  ========================================================================= }

function body_is_dynamic(const b: TBody): Boolean; inline;
begin
  Result := (b.invMass > 0) and not (BF_STATIC in b.flags);
end;

function body_active(const b: TBody): Boolean; inline;
begin
  Result := (BF_ENABLED in b.flags) and not (BF_SLEEPING in b.flags)
            and body_is_dynamic(b);
end;

procedure phys_init;
begin
  g_nbodies := 0;
  g_nmanifolds := 0;
  g_gravity := v3(0, -9.81, 0);
  g_phys_time := 0;
end;

procedure phys_clear;
begin
  g_nbodies := 0;
  g_nmanifolds := 0;
end;

function phys_pose(id: Integer): TPose;
begin
  Result.p := g_bodies[id].pos;
  Result.q := g_bodies[id].orient;
end;

function phys_add_body(const s: TShape; const pos: TVec3; const q: TQuat;
                       mass: Single): Integer;
var
  b: PBody;
  I: TMat3;
  id: Integer;
begin
  if g_nbodies >= PHYS_MAX_BODIES then
  begin
    Result := -1;
    Exit;
  end;
  id := g_nbodies;
  Inc(g_nbodies);

  g_shapes[id] := s;
  b := @g_bodies[id];
  FillChar(b^, SizeOf(TBody), 0);

  b^.pos := pos;
  b^.orient := q_norm(q);
  b^.shape := id;
  b^.friction := 0.5;
  b^.restitution := 0.1;
  b^.linDamp := 0.02;
  b^.angDamp := 0.05;
  b^.flags := [BF_ENABLED];
  b^.invIworld := m3_identity;

  if mass <= 0 then
  begin
    b^.invMass := 0;
    b^.invIlocal := v3_zero;
    b^.flags := b^.flags + [BF_STATIC];
  end
  else
  begin
    b^.invMass := 1.0 / mass;
    I := shape_inertia(s, mass);
    { Тензор диагональный -- этого достаточно для примитивов, а для
      оболочек мы его и так приближаем боксом. }
    if I.m[0] > 0 then b^.invIlocal.x := 1.0 / I.m[0];
    if I.m[4] > 0 then b^.invIlocal.y := 1.0 / I.m[4];
    if I.m[8] > 0 then b^.invIlocal.z := 1.0 / I.m[8];
  end;

  b^.box := shape_aabb(s, pose_make(pos, b^.orient), 0.05);
  Result := id;
end;

procedure phys_set_material(id: Integer; friction, restitution: Single);
begin
  if (id < 0) or (id >= g_nbodies) then Exit;
  g_bodies[id].friction := friction;
  g_bodies[id].restitution := restitution;
end;

procedure phys_wake(id: Integer);
begin
  if (id < 0) or (id >= g_nbodies) then Exit;
  g_bodies[id].flags := g_bodies[id].flags - [BF_SLEEPING];
  g_bodies[id].sleepTimer := 0;
end;

procedure phys_apply_impulse(id: Integer; const imp, point: TVec3);
var
  b: PBody;
  r: TVec3;
begin
  if (id < 0) or (id >= g_nbodies) then Exit;
  b := @g_bodies[id];
  if not body_is_dynamic(b^) then Exit;
  phys_wake(id);
  b^.linvel := v3_mad(b^.linvel, imp, b^.invMass);
  r := v3_sub(point, b^.pos);
  b^.angvel := v3_add(b^.angvel, m3_mulv(b^.invIworld, v3_cross(r, imp)));
end;

procedure phys_apply_force(id: Integer; const f: TVec3);
begin
  if (id < 0) or (id >= g_nbodies) then Exit;
  phys_wake(id);
  g_bodies[id].force := v3_add(g_bodies[id].force, f);
end;

{ Пересчёт обратного тензора инерции в мировые оси: Iw = R * Il * R^T. }
procedure update_inertia(var b: TBody); inline;
var
  R, Rt, tmp: TMat3;
  i: Integer;
begin
  if b.invMass = 0 then
  begin
    b.invIworld := m3_identity;
    b.invIworld.m[0] := 0; b.invIworld.m[4] := 0; b.invIworld.m[8] := 0;
    Exit;
  end;
  R := m3_from_quat(b.orient);
  Rt := m3_transpose(R);
  tmp := Rt;
  { умножаем строки Rt на диагональ -- дешевле полного произведения }
  for i := 0 to 2 do
  begin
    tmp.m[i * 3 + 0] := Rt.m[i * 3 + 0] * b.invIlocal.x;
    tmp.m[i * 3 + 1] := Rt.m[i * 3 + 1] * b.invIlocal.y;
    tmp.m[i * 3 + 2] := Rt.m[i * 3 + 2] * b.invIlocal.z;
  end;
  b.invIworld := m3_mul(R, tmp);
end;

{ =========================================================================
  Широкая фаза: sweep and prune по оси X

  Сортируем индексы тел по минимуму AABB (сортировка вставками -- массив
  почти отсортирован с прошлого кадра, то есть O(n)), затем сканируем
  "активный" список. Для нескольких тысяч тел это держится в единицах
  микросекунд и не плодит мусора.
  ========================================================================= }

type
  TPair = record
    a, b: Integer;
  end;

var
  g_sorted : array[0..PHYS_MAX_BODIES - 1] of Integer;
  g_nsorted: Integer = 0;
  g_pairs  : array[0..PHYS_MAX_PAIRS - 1] of TPair;
  g_npairs : Integer = 0;

procedure broadphase;
var
  i, j, k, tmp: Integer;
  minx: Single;
begin
  { 1. Поддерживаем список индексов. }
  if g_nsorted <> g_nbodies then
  begin
    for i := 0 to g_nbodies - 1 do g_sorted[i] := i;
    g_nsorted := g_nbodies;
  end;

  { 2. Сортировка вставками по g_bodies[].box.mn.x }
  for i := 1 to g_nsorted - 1 do
  begin
    tmp := g_sorted[i];
    minx := g_bodies[tmp].box.mn.x;
    j := i - 1;
    while (j >= 0) and (g_bodies[g_sorted[j]].box.mn.x > minx) do
    begin
      g_sorted[j + 1] := g_sorted[j];
      Dec(j);
    end;
    g_sorted[j + 1] := tmp;
  end;

  { 3. Скан: пока максимум по X перекрывает минимум соседа -- проверяем. }
  g_npairs := 0;
  for i := 0 to g_nsorted - 1 do
  begin
    j := g_sorted[i];
    k := i + 1;
    while k < g_nsorted do
    begin
      if g_bodies[g_sorted[k]].box.mn.x > g_bodies[j].box.mx.x then Break;

      { Два статических тела друг другу не интересны. }
      if (g_bodies[j].invMass > 0) or (g_bodies[g_sorted[k]].invMass > 0) then
        if not ((BF_SLEEPING in g_bodies[j].flags) and
                (BF_SLEEPING in g_bodies[g_sorted[k]].flags)) then
          if aabb_overlap(g_bodies[j].box, g_bodies[g_sorted[k]].box) then
            if g_npairs < PHYS_MAX_PAIRS then
            begin
              if j < g_sorted[k] then
              begin
                g_pairs[g_npairs].a := j;
                g_pairs[g_npairs].b := g_sorted[k];
              end
              else
              begin
                g_pairs[g_npairs].a := g_sorted[k];
                g_pairs[g_npairs].b := j;
              end;
              Inc(g_npairs);
            end;
      Inc(k);
    end;
  end;
  g_stat_pairs := g_npairs;
end;

{ =========================================================================
  Манифолды
  ========================================================================= }

function find_manifold(a, b: Integer): Integer;
var i: Integer;
begin
  for i := 0 to g_nmanifolds - 1 do
    if (g_manifolds[i].a = a) and (g_manifolds[i].b = b) then
    begin
      Result := i;
      Exit;
    end;
  Result := -1;
end;

{ Добавляем новую точку в манифолд. Если рядом уже есть старая точка --
  обновляем её и сохраняем накопленный импульс. }
procedure manifold_add_point(var mf: TManifold; const pa, pb, n: TVec3;
                             depth: Single);
var
  ba, bb: PBody;
  la, lb: TVec3;
  i, worst: Integer;
  d, maxd: Single;
  np: TContactPoint;
begin
  ba := @g_bodies[mf.a];
  bb := @g_bodies[mf.b];

  la := q_rotate(q_conj(ba^.orient), v3_sub(pa, ba^.pos));
  lb := q_rotate(q_conj(bb^.orient), v3_sub(pb, bb^.pos));

  { Ищем совпадение со старой точкой. }
  for i := 0 to mf.npoints - 1 do
    if (v3_distsq(mf.pt[i].localA, la) < PHYS_CONTACT_TOL * PHYS_CONTACT_TOL) or
       (v3_distsq(mf.pt[i].localB, lb) < PHYS_CONTACT_TOL * PHYS_CONTACT_TOL) then
    begin
      mf.pt[i].localA := la;
      mf.pt[i].localB := lb;
      mf.pt[i].penetration := depth;
      Inc(mf.pt[i].age);
      Exit;
    end;

  FillChar(np, SizeOf(np), 0);
  np.localA := la;
  np.localB := lb;
  np.penetration := depth;
  np.age := 0;

  if mf.npoints < PHYS_MAX_POINTS then
  begin
    mf.pt[mf.npoints] := np;
    Inc(mf.npoints);
    Exit;
  end;

  { Манифолд полон -- выкидываем точку с наименьшим вкладом: ту, что
    ближе всего к остальным (так сохраняется максимальная площадь опоры). }
  worst := 0;
  maxd := -1;
  for i := 0 to PHYS_MAX_POINTS - 1 do
  begin
    d := v3_distsq(mf.pt[i].localA, la);
    if (maxd < 0) or (d < maxd) then
    begin
      maxd := d;
      worst := i;
    end;
  end;
  mf.pt[worst] := np;
end;

{ Отбрасываем точки, которые "уехали" вместе с телами. }
procedure manifold_refresh(var mf: TManifold);
var
  i, j: Integer;
  ba, bb: PBody;
  wa, wb, dv: TVec3;
  pen, tanLen: Single;
begin
  ba := @g_bodies[mf.a];
  bb := @g_bodies[mf.b];
  j := 0;
  for i := 0 to mf.npoints - 1 do
  begin
    wa := v3_add(ba^.pos, q_rotate(ba^.orient, mf.pt[i].localA));
    wb := v3_add(bb^.pos, q_rotate(bb^.orient, mf.pt[i].localB));
    dv := v3_sub(wb, wa);
    pen := -v3_dot(dv, mf.normal);

    { 1. Точка разошлась вдоль нормали. }
    if pen < -PHYS_CONTACT_TOL then Continue;
    { 2. Точка уехала вбок (тела проскользнули). }
    tanLen := v3_lensq(v3_sub(dv, v3_mul(mf.normal, -pen)));
    if tanLen > PHYS_CONTACT_TOL * PHYS_CONTACT_TOL * 16.0 then Continue;

    mf.pt[i].penetration := pen;
    if j <> i then mf.pt[j] := mf.pt[i];
    Inc(j);
  end;
  mf.npoints := j;
end;

{ Временный буфер для уплотнения списка манифолдов. Он статический:
  класть 8192 манифолда на стек нельзя, а выделять память каждый кадр -- вредно. }
var
  g_mf_tmp: array[0..PHYS_MAX_MANIFOLDS - 1] of TManifold;

procedure narrowphase;
var
  i, k, mi: Integer;
  res: TGJKResult;
  pa, pb: TPose;
  a, b: Integer;
  mf: PManifold;
  nnew: Integer;
begin
  { Сначала помечаем все манифолды мёртвыми; выжившие пометим заново. }
  for i := 0 to g_nmanifolds - 1 do
    g_manifolds[i].alive := False;

  g_stat_contacts := 0;

  for i := 0 to g_npairs - 1 do
  begin
    a := g_pairs[i].a;
    b := g_pairs[i].b;
    pa := phys_pose(a);
    pb := phys_pose(b);

    if not gjk_collide(g_shapes[a], pa, g_shapes[b], pb, res) then
      Continue;

    mi := find_manifold(a, b);
    if mi < 0 then
    begin
      if g_nmanifolds >= PHYS_MAX_MANIFOLDS then Continue;
      mi := g_nmanifolds;
      Inc(g_nmanifolds);
      FillChar(g_manifolds[mi], SizeOf(TManifold), 0);
      g_manifolds[mi].a := a;
      g_manifolds[mi].b := b;
    end;

    mf := @g_manifolds[mi];
    mf^.alive := True;
    mf^.normal := res.normal;
    v3_basis(mf^.normal, mf^.tangent[0], mf^.tangent[1]);

    { Материалы смешиваем геометрически и по минимуму -- так делают
      почти все движки, включая Bullet. }
    mf^.friction := Sqrt(g_bodies[a].friction * g_bodies[b].friction);
    if g_bodies[a].restitution > g_bodies[b].restitution then
      mf^.restitution := g_bodies[a].restitution
    else
      mf^.restitution := g_bodies[b].restitution;

    manifold_refresh(mf^);
    manifold_add_point(mf^, res.pointA, res.pointB, res.normal, res.depth);

    Inc(g_stat_contacts, mf^.npoints);

    { Контакт будит обоих. }
    if (v3_lensq(g_bodies[a].linvel) > PHYS_SLEEP_LIN * PHYS_SLEEP_LIN) or
       (v3_lensq(g_bodies[b].linvel) > PHYS_SLEEP_LIN * PHYS_SLEEP_LIN) then
    begin
      phys_wake(a);
      phys_wake(b);
    end;
  end;

  { Уплотняем список манифолдов. }
  nnew := 0;
  for i := 0 to g_nmanifolds - 1 do
    if g_manifolds[i].alive and (g_manifolds[i].npoints > 0) then
    begin
      g_mf_tmp[nnew] := g_manifolds[i];
      Inc(nnew);
    end;
  for i := 0 to nnew - 1 do
    g_manifolds[i] := g_mf_tmp[i];
  g_nmanifolds := nnew;

  { Защита от ситуации, когда манифолд остался, а точек в нём нет. }
  for i := 0 to g_nmanifolds - 1 do
    for k := 0 to g_manifolds[i].npoints - 1 do
      g_manifolds[i].pt[k].bias := 0;
end;

{ =========================================================================
  Решатель последовательных импульсов

  Классика Catto/Quake: для каждой точки контакта считаем эффективную массу
  вдоль нормали и двух касательных, затем много раз подряд правим скорости
  малыми импульсами. Схема нетребовательна к памяти и прекрасно ложится
  в кэш, если данные лежат плотно, что у нас и сделано.
  ========================================================================= }

procedure solver_prepare(dt: Single);
var
  i, k: Integer;
  mf: PManifold;
  ba, bb: PBody;
  cp: ^TContactPoint;
  wa, wb, rv, tmpA, tmpB: TVec3;
  kn, kt, vn: Single;
  invdt: Single;
begin
  invdt := 1.0 / dt;

  for i := 0 to g_nmanifolds - 1 do
  begin
    mf := @g_manifolds[i];
    ba := @g_bodies[mf^.a];
    bb := @g_bodies[mf^.b];

    for k := 0 to mf^.npoints - 1 do
    begin
      cp := @mf^.pt[k];

      wa := v3_add(ba^.pos, q_rotate(ba^.orient, cp^.localA));
      wb := v3_add(bb^.pos, q_rotate(bb^.orient, cp^.localB));
      cp^.rA := v3_sub(wa, ba^.pos);
      cp^.rB := v3_sub(wb, bb^.pos);

      { Эффективная масса вдоль нормали:
        1/m = ima + imb + n . ((Ia^-1 (ra x n)) x ra + ...) }
      tmpA := v3_cross(m3_mulv(ba^.invIworld, v3_cross(cp^.rA, mf^.normal)), cp^.rA);
      tmpB := v3_cross(m3_mulv(bb^.invIworld, v3_cross(cp^.rB, mf^.normal)), cp^.rB);
      kn := ba^.invMass + bb^.invMass +
            v3_dot(mf^.normal, v3_add(tmpA, tmpB));
      if kn > EPS then cp^.massNormal := 1.0 / kn else cp^.massNormal := 0;

      tmpA := v3_cross(m3_mulv(ba^.invIworld, v3_cross(cp^.rA, mf^.tangent[0])), cp^.rA);
      tmpB := v3_cross(m3_mulv(bb^.invIworld, v3_cross(cp^.rB, mf^.tangent[0])), cp^.rB);
      kt := ba^.invMass + bb^.invMass + v3_dot(mf^.tangent[0], v3_add(tmpA, tmpB));
      if kt > EPS then cp^.massTang[0] := 1.0 / kt else cp^.massTang[0] := 0;

      tmpA := v3_cross(m3_mulv(ba^.invIworld, v3_cross(cp^.rA, mf^.tangent[1])), cp^.rA);
      tmpB := v3_cross(m3_mulv(bb^.invIworld, v3_cross(cp^.rB, mf^.tangent[1])), cp^.rB);
      kt := ba^.invMass + bb^.invMass + v3_dot(mf^.tangent[1], v3_add(tmpA, tmpB));
      if kt > EPS then cp^.massTang[1] := 1.0 / kt else cp^.massTang[1] := 0;

      { Смещение Баумгарта: загоняем проникновение обратно, но не быстрее
        PHYS_MAX_CORRECT за шаг, иначе стопки тел взрываются. }
      cp^.bias := -PHYS_BAUMGARTE * invdt *
                  fmin(fmax(cp^.penetration - PHYS_SLOP, 0.0), PHYS_MAX_CORRECT);

      { Запоминаем скорость сближения для расчёта отскока. }
      rv := v3_sub(v3_add(bb^.linvel, v3_cross(bb^.angvel, cp^.rB)),
                   v3_add(ba^.linvel, v3_cross(ba^.angvel, cp^.rA)));
      vn := v3_dot(rv, mf^.normal);
      cp^.relvel0 := vn;

      { Тёплый старт: сразу прикладываем импульсы с прошлого кадра.
        Это главное, что делает стопки ящиков устойчивыми. }
      if cp^.age > 0 then
      begin
        tmpA := v3_add(v3_mul(mf^.normal, cp^.normalImpulse),
                v3_add(v3_mul(mf^.tangent[0], cp^.tangImpulse[0]),
                       v3_mul(mf^.tangent[1], cp^.tangImpulse[1])));
        if ba^.invMass > 0 then
        begin
          ba^.linvel := v3_mad(ba^.linvel, tmpA, -ba^.invMass);
          ba^.angvel := v3_sub(ba^.angvel,
            m3_mulv(ba^.invIworld, v3_cross(cp^.rA, tmpA)));
        end;
        if bb^.invMass > 0 then
        begin
          bb^.linvel := v3_mad(bb^.linvel, tmpA, bb^.invMass);
          bb^.angvel := v3_add(bb^.angvel,
            m3_mulv(bb^.invIworld, v3_cross(cp^.rB, tmpA)));
        end;
      end
      else
      begin
        cp^.normalImpulse := 0;
        cp^.tangImpulse[0] := 0;
        cp^.tangImpulse[1] := 0;
      end;
    end;
  end;
end;

procedure solver_iterate;
var
  i, k, t: Integer;
  mf: PManifold;
  ba, bb: PBody;
  cp: ^TContactPoint;
  rv, imp: TVec3;
  vn, vt, lambda, oldimp, maxf, rest: Single;
begin
  for i := 0 to g_nmanifolds - 1 do
  begin
    mf := @g_manifolds[i];
    ba := @g_bodies[mf^.a];
    bb := @g_bodies[mf^.b];

    for k := 0 to mf^.npoints - 1 do
    begin
      cp := @mf^.pt[k];

      { --- трение (считаем до нормали: так устойчивее при больших силах) --- }
      for t := 0 to 1 do
      begin
        rv := v3_sub(v3_add(bb^.linvel, v3_cross(bb^.angvel, cp^.rB)),
                     v3_add(ba^.linvel, v3_cross(ba^.angvel, cp^.rA)));
        vt := v3_dot(rv, mf^.tangent[t]);
        lambda := -vt * cp^.massTang[t];

        maxf := mf^.friction * cp^.normalImpulse;
        oldimp := cp^.tangImpulse[t];
        cp^.tangImpulse[t] := fclamp(oldimp + lambda, -maxf, maxf);
        lambda := cp^.tangImpulse[t] - oldimp;

        imp := v3_mul(mf^.tangent[t], lambda);
        if ba^.invMass > 0 then
        begin
          ba^.linvel := v3_mad(ba^.linvel, imp, -ba^.invMass);
          ba^.angvel := v3_sub(ba^.angvel,
            m3_mulv(ba^.invIworld, v3_cross(cp^.rA, imp)));
        end;
        if bb^.invMass > 0 then
        begin
          bb^.linvel := v3_mad(bb^.linvel, imp, bb^.invMass);
          bb^.angvel := v3_add(bb^.angvel,
            m3_mulv(bb^.invIworld, v3_cross(cp^.rB, imp)));
        end;
      end;

      { --- нормаль --- }
      rv := v3_sub(v3_add(bb^.linvel, v3_cross(bb^.angvel, cp^.rB)),
                   v3_add(ba^.linvel, v3_cross(ba^.angvel, cp^.rA)));
      vn := v3_dot(rv, mf^.normal);

      { Отскок включаем только при заметной скорости удара, иначе тела
        никогда не успокоятся. }
      rest := 0;
      if cp^.relvel0 < -PHYS_REST_THRESH then
        rest := -mf^.restitution * cp^.relvel0;

      lambda := -(vn - rest + cp^.bias) * cp^.massNormal;

      { Проекция на допустимое множество: суммарный импульс >= 0. }
      oldimp := cp^.normalImpulse;
      cp^.normalImpulse := fmax(oldimp + lambda, 0.0);
      lambda := cp^.normalImpulse - oldimp;

      imp := v3_mul(mf^.normal, lambda);
      if ba^.invMass > 0 then
      begin
        ba^.linvel := v3_mad(ba^.linvel, imp, -ba^.invMass);
        ba^.angvel := v3_sub(ba^.angvel,
          m3_mulv(ba^.invIworld, v3_cross(cp^.rA, imp)));
      end;
      if bb^.invMass > 0 then
      begin
        bb^.linvel := v3_mad(bb^.linvel, imp, bb^.invMass);
        bb^.angvel := v3_add(bb^.angvel,
          m3_mulv(bb^.invIworld, v3_cross(cp^.rB, imp)));
      end;
    end;
  end;
end;

{ Прямая позиционная коррекция остаточного проникновения.
  Делается после решателя скоростей и не вносит энергии в систему. }
procedure solver_positions;
var
  i, k, it: Integer;
  mf: PManifold;
  ba, bb: PBody;
  cp: ^TContactPoint;
  wa, wb: TVec3;
  pen, corr, totalInv: Single;
begin
  for it := 1 to PHYS_POS_ITERS do
    for i := 0 to g_nmanifolds - 1 do
    begin
      mf := @g_manifolds[i];
      ba := @g_bodies[mf^.a];
      bb := @g_bodies[mf^.b];
      totalInv := ba^.invMass + bb^.invMass;
      if totalInv <= EPS then Continue;

      for k := 0 to mf^.npoints - 1 do
      begin
        cp := @mf^.pt[k];
        wa := v3_add(ba^.pos, q_rotate(ba^.orient, cp^.localA));
        wb := v3_add(bb^.pos, q_rotate(bb^.orient, cp^.localB));
        pen := -v3_dot(v3_sub(wb, wa), mf^.normal);
        if pen <= PHYS_SLOP then Continue;

        corr := fmin(pen - PHYS_SLOP, PHYS_MAX_CORRECT) * 0.4 / totalInv;
        if ba^.invMass > 0 then
          ba^.pos := v3_mad(ba^.pos, mf^.normal, -corr * ba^.invMass);
        if bb^.invMass > 0 then
          bb^.pos := v3_mad(bb^.pos, mf^.normal, corr * bb^.invMass);
      end;
    end;
end;

{ =========================================================================
  Интегрирование
  ========================================================================= }

procedure integrate_velocities(dt: Single);
var
  i: Integer;
  b: PBody;
  ld, ad: Single;
begin
  for i := 0 to g_nbodies - 1 do
  begin
    b := @g_bodies[i];
    if not body_active(b^) then
    begin
      b^.force := v3_zero;
      b^.torque := v3_zero;
      Continue;
    end;

    update_inertia(b^);

    b^.linvel := v3_add(b^.linvel,
      v3_mul(v3_add(g_gravity, v3_mul(b^.force, b^.invMass)), dt));
    b^.angvel := v3_add(b^.angvel, v3_mul(m3_mulv(b^.invIworld, b^.torque), dt));

    { Экспоненциальное затухание, независимое от шага. }
    ld := 1.0 / (1.0 + dt * b^.linDamp * 10.0);
    ad := 1.0 / (1.0 + dt * b^.angDamp * 10.0);
    b^.linvel := v3_mul(b^.linvel, ld);
    b^.angvel := v3_mul(b^.angvel, ad);

    b^.force := v3_zero;
    b^.torque := v3_zero;
  end;
end;

procedure integrate_positions(dt: Single);
var
  i: Integer;
  b: PBody;
  v2, w2: Single;
begin
  g_stat_awake := 0;
  for i := 0 to g_nbodies - 1 do
  begin
    b := @g_bodies[i];
    if not body_active(b^) then Continue;

    b^.pos := v3_mad(b^.pos, b^.linvel, dt);
    if not (BF_LOCK_ROT in b^.flags) then
      b^.orient := q_integrate(b^.orient, b^.angvel, dt);

    { Засыпание: тело, которое долго почти не двигается, выключается
      до следующего контакта. Это даёт основной выигрыш в больших сценах. }
    v2 := v3_lensq(b^.linvel);
    w2 := v3_lensq(b^.angvel);
    if (v2 < PHYS_SLEEP_LIN * PHYS_SLEEP_LIN) and
       (w2 < PHYS_SLEEP_ANG * PHYS_SLEEP_ANG) and
       not (BF_NOSLEEP in b^.flags) then
    begin
      b^.sleepTimer := b^.sleepTimer + dt;
      if b^.sleepTimer > PHYS_SLEEP_TIME then
      begin
        b^.flags := b^.flags + [BF_SLEEPING];
        b^.linvel := v3_zero;
        b^.angvel := v3_zero;
      end;
    end
    else
      b^.sleepTimer := 0;

    Inc(g_stat_awake);
  end;

  { Обновляем AABB только у тех, кто двигался. }
  for i := 0 to g_nbodies - 1 do
  begin
    b := @g_bodies[i];
    if (BF_SLEEPING in b^.flags) and (b^.box.mx.x > b^.box.mn.x) then Continue;
    b^.box := shape_aabb(g_shapes[i], pose_make(b^.pos, b^.orient), 0.05);
  end;
end;

procedure phys_step(dt: Single);
var i: Integer;
begin
  if dt <= 0 then Exit;

  { Пробуждаем всех, кого коснулась внешняя сила. }
  for i := 0 to g_nbodies - 1 do
    if not v3_iszero(g_bodies[i].force) then phys_wake(i);

  integrate_velocities(dt);
  broadphase;
  narrowphase;

  solver_prepare(dt);
  for i := 1 to PHYS_VEL_ITERS do
    solver_iterate;

  integrate_positions(dt);
  solver_positions;

  g_phys_time := g_phys_time + dt;
end;

{ =========================================================================
  Трассировка луча
  ========================================================================= }

{ Быстрый отбор по AABB методом плит (slab method). }
function ray_aabb(const ro, inv: TVec3; const b: TAABB; maxd: Single): Boolean;
var
  t1, t2, tmin, tmax: Single;
begin
  t1 := (b.mn.x - ro.x) * inv.x;
  t2 := (b.mx.x - ro.x) * inv.x;
  tmin := fmin(t1, t2); tmax := fmax(t1, t2);
  t1 := (b.mn.y - ro.y) * inv.y;
  t2 := (b.mx.y - ro.y) * inv.y;
  tmin := fmax(tmin, fmin(t1, t2)); tmax := fmin(tmax, fmax(t1, t2));
  t1 := (b.mn.z - ro.z) * inv.z;
  t2 := (b.mx.z - ro.z) * inv.z;
  tmin := fmax(tmin, fmin(t1, t2)); tmax := fmin(tmax, fmax(t1, t2));
  Result := (tmax >= fmax(tmin, 0.0)) and (tmin <= maxd);
end;

function phys_raycast(const ro, rd: TVec3; maxdist: Single): TRayHit;
var
  i: Integer;
  inv, d: TVec3;
  n: TVec3;
  t: Single;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.body := -1;
  Result.distance := maxdist;

  d := v3_norm(rd);
  inv.x := 1.0 / (d.x + 1.0e-12);
  inv.y := 1.0 / (d.y + 1.0e-12);
  inv.z := 1.0 / (d.z + 1.0e-12);

  for i := 0 to g_nbodies - 1 do
  begin
    if not (BF_ENABLED in g_bodies[i].flags) then Continue;
    if not ray_aabb(ro, inv, g_bodies[i].box, Result.distance) then Continue;

    if gjk_raycast(g_shapes[i], phys_pose(i), ro, d, Result.distance, t, n) then
      if t < Result.distance then
      begin
        Result.hit := True;
        Result.body := i;
        Result.distance := t;
        Result.point := v3_mad(ro, d, t);
        Result.normal := n;
      end;
  end;
end;

initialization
  g_gravity := v3(0, -9.81, 0);

end.
