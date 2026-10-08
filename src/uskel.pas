{ ============================================================================
  uskel.pas  --  скелет, позы, анимационные клипы и скиннинг

  Стиль тот же, что и во всём движке: никаких классов, только записи и
  процедуры, всё хранится в плоских массивах.

  Три разных понятия, которые легко спутать:

    * ПОЗА (TSkelPose) -- набор ЛОКАЛЬНЫХ трансформов костей относительно
      родителей. Это то, что выдаёт анимация и чем управляет рэгдол.
    * МИРОВЫЕ трансформы -- результат прямой кинематики по позе.
    * МАТРИЦЫ СКИННИНГА -- мировая матрица кости, умноженная на обратную
      матрицу привязки. Именно они гонят вершины.

  Кости обязаны идти в порядке "родитель раньше ребёнка": тогда прямая
  кинематика -- один линейный проход по массиву, без рекурсии и без стека.
  ============================================================================ }
unit uskel;

{$MODE OBJFPC}
{$H+}
{$INLINE ON}

interface

uses
  SysUtils, Math, umath;

const
  SK_MAX_BONES    = 128;
  SK_MAX_CHANNELS = 128;
  SK_MAX_KEYS     = 64;
  SK_ROOT         = -1;

type
  TBone = record
    name      : string[31];
    parent    : Integer;      { -1 для корня, всегда меньше своего индекса }
    bind      : TTransform;   { локальный трансформ в позе привязки }
    bindWInv  : TMat4;        { обратная мировая матрица привязки }
    bindWorld : TTransform;   { мировой трансформ в позе привязки }
    length    : Single;       { до первого ребёнка; для рэгдола и отладки }
    dirLocal  : TVec3;        { направление на ребёнка в локальных осях }
  end;

  TSkeleton = record
    nbones: Integer;
    bone  : array[0..SK_MAX_BONES - 1] of TBone;
  end;
  PSkeleton = ^TSkeleton;

  { Поза: локальные трансформы всех костей. }
  TSkelPose = record
    n     : Integer;
    local : array[0..SK_MAX_BONES - 1] of TTransform;
  end;

  { Маска слоя: вес кости при наложении. 0 -- кость не трогаем. }
  TBoneMask = record
    n: Integer;
    w: array[0..SK_MAX_BONES - 1] of Single;
  end;

  { --- анимация --- }
  TPosKey = record
    t: Single;
    v: TVec3;
  end;

  TRotKey = record
    t: Single;
    q: TQuat;
  end;

  TAnimChannel = record
    bone : Integer;
    npos : Integer;
    nrot : Integer;
    pos  : array[0..SK_MAX_KEYS - 1] of TPosKey;
    rot  : array[0..SK_MAX_KEYS - 1] of TRotKey;
  end;

  TAnimClip = record
    name     : string[31];
    duration : Single;
    loop     : Boolean;
    nchan    : Integer;
    chan     : array[0..SK_MAX_CHANNELS - 1] of TAnimChannel;
  end;
  PAnimClip = ^TAnimClip;

  { --- скиннинг --- }
  TSkinVertex = record
    pos, nrm : TVec3;
    bone     : array[0..3] of Byte;
    weight   : array[0..3] of Single;
  end;
  TSkinArray = array of TSkinVertex;

  TMatrixPalette = array[0..SK_MAX_BONES - 1] of TMat4;

{ --- скелет --- }
procedure skel_clear(out s: TSkeleton);
function  skel_add_bone(var s: TSkeleton; const name: string; parent: Integer;
                        const bindLocal: TTransform): Integer;
{ Досчитывает мировые матрицы привязки, длины и направления костей.
  Вызывать после того, как все кости добавлены. }
procedure skel_finalize(var s: TSkeleton);
function  skel_find(const s: TSkeleton; const name: string): Integer;

{ --- позы --- }
procedure pose_bind(const s: TSkeleton; out p: TSkelPose);
procedure pose_copy(const src: TSkelPose; out dst: TSkelPose);
{ Линейное смешивание двух поз (повороты -- slerp). }
procedure pose_blend(const a, b: TSkelPose; t: Single; var r: TSkelPose);
{ То же, но вес берётся из маски: так накладывают верх тела поверх низа. }
procedure pose_blend_masked(const a, b: TSkelPose; t: Single;
                            const mask: TBoneMask; var r: TSkelPose);
{ Аддитивный слой: к базовой позе добавляется разница (add - ref). }
procedure pose_additive(const base, refpose, add: TSkelPose; w: Single;
                        var r: TSkelPose);

procedure mask_clear(out m: TBoneMask; n: Integer; value: Single);
{ Ставит вес кости и всем её потомкам -- типичная операция для масок. }
procedure mask_set_chain(var m: TBoneMask; const s: TSkeleton;
                         root: Integer; value: Single);

{ --- кинематика --- }
procedure skel_world(const s: TSkeleton; const p: TSkelPose;
                     const rootXform: TTransform; out w: TSkelPose);
procedure skel_palette(const s: TSkeleton; const w: TSkelPose;
                       out pal: TMatrixPalette);
{ Мировой трансформ одной кости без расчёта всей иерархии. }
function  skel_bone_world(const s: TSkeleton; const p: TSkelPose;
                          const rootXform: TTransform; bone: Integer): TTransform;

{ --- анимация --- }
procedure clip_clear(out c: TAnimClip; const name: string; duration: Single;
                     loop: Boolean);
function  clip_channel(var c: TAnimClip; bone: Integer): Integer;
procedure clip_add_rot(var c: TAnimClip; bone: Integer; t: Single;
                       const q: TQuat);
procedure clip_add_pos(var c: TAnimClip; bone: Integer; t: Single;
                       const v: TVec3);
{ Выборка клипа в позу. Кости, которых нет в клипе, остаются как были. }
procedure anim_sample(const c: TAnimClip; time: Single; var p: TSkelPose);

{ --- скиннинг --- }
{ Классический linear blend skinning. Нормали гонятся теми же матрицами:
  для поворотов и равномерного масштаба этого достаточно. }
procedure skin_apply(const pal: TMatrixPalette; const src: TSkinArray;
                     var outPos, outNrm: array of TVec3);
{ Привязка точки к ближайшим костям -- чтобы не писать веса руками. }
procedure skin_autoweight(const s: TSkeleton; const bindWorld: TSkelPose;
                          var v: TSkinVertex; maxBones: Integer);

implementation

{ =========================================================================
  Скелет
  ========================================================================= }

procedure skel_clear(out s: TSkeleton);
begin
  FillChar(s, SizeOf(TSkeleton), 0);
  s.nbones := 0;
end;

function skel_add_bone(var s: TSkeleton; const name: string; parent: Integer;
                       const bindLocal: TTransform): Integer;
begin
  Result := -1;
  if s.nbones >= SK_MAX_BONES then Exit;
  { Порядок обязателен: родитель должен быть уже добавлен. }
  if (parent >= s.nbones) then Exit;
  Result := s.nbones;
  Inc(s.nbones);
  s.bone[Result].name := name;
  s.bone[Result].parent := parent;
  s.bone[Result].bind := bindLocal;
  s.bone[Result].length := 0;
  s.bone[Result].dirLocal := v3(0, 1, 0);
end;

function xform_mul(const a, b: TTransform): TTransform; inline;
begin
  { сначала b, потом a: как умножение матриц }
  Result.rot := q_mul(a.rot, b.rot);
  Result.pos := v3_add(a.pos, q_rotate(a.rot, b.pos));
end;

function xform_identity: TTransform; inline;
begin
  Result.pos := v3_zero;
  Result.rot := q_identity;
end;

function xform_to_mat(const t: TTransform): TMat4; inline;
begin
  Result := m4_compose(t.pos, t.rot, v3(1, 1, 1));
end;

procedure skel_finalize(var s: TSkeleton);
var
  i, j, child: Integer;
  w: TTransform;
  d: TVec3;
begin
  for i := 0 to s.nbones - 1 do
  begin
    if s.bone[i].parent = SK_ROOT then
      w := s.bone[i].bind
    else
      w := xform_mul(s.bone[s.bone[i].parent].bindWorld, s.bone[i].bind);
    s.bone[i].bindWorld := w;
    s.bone[i].bindWInv := m4_inverse_affine(xform_to_mat(w));
  end;

  { Длина кости -- расстояние до первого ребёнка. У листьев длины нет,
    поэтому им отдаём длину родителя: так рэгдол получает разумный
    размер для кистей и стоп. }
  for i := 0 to s.nbones - 1 do
  begin
    child := -1;
    for j := i + 1 to s.nbones - 1 do
      if s.bone[j].parent = i then
      begin
        child := j;
        Break;
      end;
    if child >= 0 then
    begin
      d := s.bone[child].bind.pos;
      s.bone[i].length := v3_len(d);
      if s.bone[i].length > EPS then
        s.bone[i].dirLocal := v3_mul(d, 1.0 / s.bone[i].length)
      else
        s.bone[i].dirLocal := v3(0, 1, 0);
    end
    else
    begin
      if s.bone[i].parent >= 0 then
        s.bone[i].length := s.bone[s.bone[i].parent].length * 0.5
      else
        s.bone[i].length := 0.1;
      s.bone[i].dirLocal := v3(0, 1, 0);
    end;
  end;
end;

function skel_find(const s: TSkeleton; const name: string): Integer;
var i: Integer;
begin
  for i := 0 to s.nbones - 1 do
    if s.bone[i].name = name then
    begin
      Result := i;
      Exit;
    end;
  Result := -1;
end;

{ =========================================================================
  Позы
  ========================================================================= }

procedure pose_bind(const s: TSkeleton; out p: TSkelPose);
var i: Integer;
begin
  p.n := s.nbones;
  for i := 0 to s.nbones - 1 do
    p.local[i] := s.bone[i].bind;
end;

procedure pose_copy(const src: TSkelPose; out dst: TSkelPose);
var i: Integer;
begin
  dst.n := src.n;
  for i := 0 to src.n - 1 do dst.local[i] := src.local[i];
end;

procedure pose_blend(const a, b: TSkelPose; t: Single; var r: TSkelPose);
var i: Integer;
begin
  r.n := a.n;
  for i := 0 to a.n - 1 do
  begin
    r.local[i].pos := v3_lerp(a.local[i].pos, b.local[i].pos, t);
    r.local[i].rot := q_slerp(a.local[i].rot, b.local[i].rot, t);
  end;
end;

procedure pose_blend_masked(const a, b: TSkelPose; t: Single;
                            const mask: TBoneMask; var r: TSkelPose);
var
  i: Integer;
  w: Single;
begin
  r.n := a.n;
  for i := 0 to a.n - 1 do
  begin
    w := t;
    if i < mask.n then w := t * mask.w[i];
    if w <= 0 then
      r.local[i] := a.local[i]
    else
    begin
      r.local[i].pos := v3_lerp(a.local[i].pos, b.local[i].pos, w);
      r.local[i].rot := q_slerp(a.local[i].rot, b.local[i].rot, w);
    end;
  end;
end;

procedure pose_additive(const base, refpose, add: TSkelPose; w: Single;
                        var r: TSkelPose);
var
  i: Integer;
  dq: TQuat;
begin
  r.n := base.n;
  for i := 0 to base.n - 1 do
  begin
    { разница слоя относительно его опорной позы }
    dq := q_mul(add.local[i].rot, q_conj(refpose.local[i].rot));
    r.local[i].rot := q_norm(q_mul(q_slerp(q_identity, dq, w),
                                   base.local[i].rot));
    r.local[i].pos := v3_add(base.local[i].pos,
                             v3_mul(v3_sub(add.local[i].pos,
                                           refpose.local[i].pos), w));
  end;
end;

procedure mask_clear(out m: TBoneMask; n: Integer; value: Single);
var i: Integer;
begin
  m.n := n;
  for i := 0 to n - 1 do m.w[i] := value;
end;

procedure mask_set_chain(var m: TBoneMask; const s: TSkeleton;
                         root: Integer; value: Single);
var i: Integer;
begin
  if (root < 0) or (root >= s.nbones) then Exit;
  m.w[root] := value;
  { кости идут сверху вниз, поэтому одного прохода достаточно }
  for i := root + 1 to s.nbones - 1 do
    if (s.bone[i].parent >= 0) and (m.w[s.bone[i].parent] = value) then
      m.w[i] := value;
end;

{ =========================================================================
  Кинематика
  ========================================================================= }

procedure skel_world(const s: TSkeleton; const p: TSkelPose;
                     const rootXform: TTransform; out w: TSkelPose);
var i: Integer;
begin
  w.n := s.nbones;
  for i := 0 to s.nbones - 1 do
    if s.bone[i].parent = SK_ROOT then
      w.local[i] := xform_mul(rootXform, p.local[i])
    else
      w.local[i] := xform_mul(w.local[s.bone[i].parent], p.local[i]);
end;

function skel_bone_world(const s: TSkeleton; const p: TSkelPose;
                         const rootXform: TTransform; bone: Integer): TTransform;
var
  chain: array[0..SK_MAX_BONES - 1] of Integer;
  n, i: Integer;
begin
  n := 0;
  i := bone;
  while (i >= 0) and (n < SK_MAX_BONES) do
  begin
    chain[n] := i;
    Inc(n);
    i := s.bone[i].parent;
  end;
  Result := rootXform;
  for i := n - 1 downto 0 do
    Result := xform_mul(Result, p.local[chain[i]]);
end;

procedure skel_palette(const s: TSkeleton; const w: TSkelPose;
                       out pal: TMatrixPalette);
var i: Integer;
begin
  for i := 0 to s.nbones - 1 do
    pal[i] := m4_mul(xform_to_mat(w.local[i]), s.bone[i].bindWInv);
end;

{ =========================================================================
  Анимация
  ========================================================================= }

procedure clip_clear(out c: TAnimClip; const name: string; duration: Single;
                     loop: Boolean);
begin
  FillChar(c, SizeOf(TAnimClip), 0);
  c.name := name;
  c.duration := duration;
  c.loop := loop;
  c.nchan := 0;
end;

function clip_channel(var c: TAnimClip; bone: Integer): Integer;
var i: Integer;
begin
  for i := 0 to c.nchan - 1 do
    if c.chan[i].bone = bone then
    begin
      Result := i;
      Exit;
    end;
  Result := -1;
  if c.nchan >= SK_MAX_CHANNELS then Exit;
  Result := c.nchan;
  Inc(c.nchan);
  c.chan[Result].bone := bone;
  c.chan[Result].npos := 0;
  c.chan[Result].nrot := 0;
end;

procedure clip_add_rot(var c: TAnimClip; bone: Integer; t: Single;
                       const q: TQuat);
var ch, n: Integer;
begin
  ch := clip_channel(c, bone);
  if ch < 0 then Exit;
  n := c.chan[ch].nrot;
  if n >= SK_MAX_KEYS then Exit;
  c.chan[ch].rot[n].t := t;
  c.chan[ch].rot[n].q := q_norm(q);
  c.chan[ch].nrot := n + 1;
end;

procedure clip_add_pos(var c: TAnimClip; bone: Integer; t: Single;
                       const v: TVec3);
var ch, n: Integer;
begin
  ch := clip_channel(c, bone);
  if ch < 0 then Exit;
  n := c.chan[ch].npos;
  if n >= SK_MAX_KEYS then Exit;
  c.chan[ch].pos[n].t := t;
  c.chan[ch].pos[n].v := v;
  c.chan[ch].npos := n + 1;
end;

procedure anim_sample(const c: TAnimClip; time: Single; var p: TSkelPose);
var
  i, k, b: Integer;
  t, u: Single;
begin
  t := time;
  if c.loop and (c.duration > EPS) then
  begin
    t := t - Floor(t / c.duration) * c.duration;
  end
  else
    t := fclamp(t, 0, c.duration);

  for i := 0 to c.nchan - 1 do
  begin
    b := c.chan[i].bone;
    if (b < 0) or (b >= p.n) then Continue;

    { --- поворот --- }
    if c.chan[i].nrot = 1 then
      p.local[b].rot := c.chan[i].rot[0].q
    else if c.chan[i].nrot > 1 then
    begin
      k := 0;
      while (k < c.chan[i].nrot - 2) and (c.chan[i].rot[k + 1].t <= t) do Inc(k);
      u := c.chan[i].rot[k + 1].t - c.chan[i].rot[k].t;
      if u > EPS then u := (t - c.chan[i].rot[k].t) / u else u := 0;
      u := fclamp(u, 0, 1);
      p.local[b].rot := q_slerp(c.chan[i].rot[k].q, c.chan[i].rot[k + 1].q, u);
    end;

    { --- смещение --- }
    if c.chan[i].npos = 1 then
      p.local[b].pos := c.chan[i].pos[0].v
    else if c.chan[i].npos > 1 then
    begin
      k := 0;
      while (k < c.chan[i].npos - 2) and (c.chan[i].pos[k + 1].t <= t) do Inc(k);
      u := c.chan[i].pos[k + 1].t - c.chan[i].pos[k].t;
      if u > EPS then u := (t - c.chan[i].pos[k].t) / u else u := 0;
      u := fclamp(u, 0, 1);
      p.local[b].pos := v3_lerp(c.chan[i].pos[k].v, c.chan[i].pos[k + 1].v, u);
    end;
  end;
end;

{ =========================================================================
  Скиннинг
  ========================================================================= }

procedure skin_apply(const pal: TMatrixPalette; const src: TSkinArray;
                     var outPos, outNrm: array of TVec3);
var
  i, k, b: Integer;
  wsum, w: Single;
  p, n: TVec3;
begin
  for i := 0 to High(src) do
  begin
    p := v3_zero;
    n := v3_zero;
    wsum := 0;
    for k := 0 to 3 do
    begin
      w := src[i].weight[k];
      if w <= 0 then Continue;
      b := src[i].bone[k];
      p := v3_add(p, v3_mul(m4_transform_point(pal[b], src[i].pos), w));
      n := v3_add(n, v3_mul(m4_transform_dir(pal[b], src[i].nrm), w));
      wsum := wsum + w;
    end;
    if wsum > EPS then
    begin
      outPos[i] := v3_mul(p, 1.0 / wsum);
      outNrm[i] := v3_norm(n);
    end
    else
    begin
      outPos[i] := src[i].pos;
      outNrm[i] := src[i].nrm;
    end;
  end;
end;

{ Расстояние от точки до отрезка кости. }
function dist_to_bone(const s: TSkeleton; const bw: TSkelPose;
                      bone: Integer; const p: TVec3): Single;
var
  a, b, ab, ap: TVec3;
  t, l2: Single;
begin
  a := bw.local[bone].pos;
  b := v3_add(a, q_rotate(bw.local[bone].rot,
                          v3_mul(s.bone[bone].dirLocal, s.bone[bone].length)));
  ab := v3_sub(b, a);
  l2 := v3_lensq(ab);
  if l2 < EPS then
  begin
    Result := v3_dist(p, a);
    Exit;
  end;
  ap := v3_sub(p, a);
  t := fclamp(v3_dot(ap, ab) / l2, 0, 1);
  Result := v3_dist(p, v3_mad(a, ab, t));
end;

procedure skin_autoweight(const s: TSkeleton; const bindWorld: TSkelPose;
                          var v: TSkinVertex; maxBones: Integer);
var
  i, k, worst: Integer;
  d, sum: Single;
  bd: array[0..3] of Single;
begin
  for k := 0 to 3 do
  begin
    v.bone[k] := 0;
    v.weight[k] := 0;
    bd[k] := 1.0e30;
  end;
  if maxBones > 4 then maxBones := 4;

  { отбираем maxBones ближайших костей }
  for i := 0 to s.nbones - 1 do
  begin
    d := dist_to_bone(s, bindWorld, i, v.pos);
    worst := -1;
    for k := 0 to maxBones - 1 do
      if (worst < 0) or (bd[k] > bd[worst]) then worst := k;
    if d < bd[worst] then
    begin
      bd[worst] := d;
      v.bone[worst] := i;
    end;
  end;

  { вес обратно пропорционален расстоянию, с мягким спадом }
  sum := 0;
  for k := 0 to maxBones - 1 do
    if bd[k] < 1.0e29 then
    begin
      v.weight[k] := 1.0 / (bd[k] * bd[k] + 1.0e-4);
      sum := sum + v.weight[k];
    end;
  if sum > EPS then
    for k := 0 to 3 do v.weight[k] := v.weight[k] / sum;
end;

end.
