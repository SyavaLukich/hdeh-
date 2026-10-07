{ ============================================================================
  umath.pas  --  математическая библиотека 3D-движка

  Стиль кода: только записи (records), только процедуры, никаких классов.
  Все функции, кроме тяжёлых, помечены inline и живут в одном модуле.
  Используется исключительно формат Single (4 байта) -- он оптимален для
  видеокарты и хорошо ложится в SSE/AVX-регистры.
  ============================================================================ }
unit umath;

{$MODE OBJFPC}
{$H+}
{$INLINE ON}
{$OPTIMIZATION LEVEL3}
{$OPTIMIZATION REGVAR}

interface

const
  EPS      = 1.0e-6;
  EPS_SQR  = 1.0e-12;
  PI_F     = 3.14159265358979;
  DEG2RAD  = PI_F / 180.0;
  RAD2DEG  = 180.0 / PI_F;

type
  { Вектор 3D. Хранится плотно (12 байт) -- так выгоднее для больших
    массивов вершин, которые уходят прямо в видеопамять. }
  TVec3 = record
    x, y, z: Single;
  end;
  PVec3 = ^TVec3;

  TVec4 = record
    x, y, z, w: Single;
  end;
  PVec4 = ^TVec4;

  { Матрица 4x4, column-major -- раскладка та же, что и в OpenGL,
    поэтому glUniformMatrix4fv получает её без транспонирования. }
  TMat4 = record
    m: array[0..15] of Single;
  end;
  PMat4 = ^TMat4;

  TMat3 = record
    m: array[0..8] of Single;
  end;

  { Кватернион для хранения ориентации: нет гимбал-лока и дёшево
    интерполируется. }
  TQuat = record
    x, y, z, w: Single;
  end;

  { Плоскость в форме n*p + d = 0 }
  TPlane = record
    n: TVec3;
    d: Single;
  end;

  { Осеориентированный ограничивающий бокс }
  TAABB = record
    mn, mx: TVec3;
  end;

  { Пирамида видимости -- 6 плоскостей отсечения }
  TFrustum = record
    p: array[0..5] of TPlane;
  end;

  TTransform = record
    pos: TVec3;
    rot: TQuat;
  end;

{ ---------------------------------------------------------------- векторы }
function  v3(const ax, ay, az: Single): TVec3; inline;
function  v4_make(const ax, ay, az, aw: Single): TVec4; inline;
function  v3_zero: TVec3; inline;
function  v3_add(const a, b: TVec3): TVec3; inline;
function  v3_sub(const a, b: TVec3): TVec3; inline;
function  v3_mul(const a: TVec3; const s: Single): TVec3; inline;
function  v3_mula(const a, b: TVec3): TVec3; inline;
function  v3_neg(const a: TVec3): TVec3; inline;
function  v3_mad(const a, b: TVec3; const s: Single): TVec3; inline;
function  v3_dot(const a, b: TVec3): Single; inline;
function  v3_cross(const a, b: TVec3): TVec3; inline;
function  v3_len(const a: TVec3): Single; inline;
function  v3_lensq(const a: TVec3): Single; inline;
function  v3_dist(const a, b: TVec3): Single; inline;
function  v3_distsq(const a, b: TVec3): Single; inline;
function  v3_norm(const a: TVec3): TVec3; inline;
function  v3_lerp(const a, b: TVec3; const t: Single): TVec3; inline;
function  v3_min(const a, b: TVec3): TVec3; inline;
function  v3_max(const a, b: TVec3): TVec3; inline;
function  v3_abs(const a: TVec3): TVec3; inline;
function  v3_maxcomp(const a: TVec3): Single; inline;
function  v3_iszero(const a: TVec3): Boolean; inline;
function  v3_reflect(const v, n: TVec3): TVec3; inline;
procedure v3_basis(const n: TVec3; out t1, t2: TVec3);

{ ---------------------------------------------------------------- матрицы }
function  m4_identity: TMat4;
function  m4_mul(const a, b: TMat4): TMat4;
function  m4_translate(const t: TVec3): TMat4;
function  m4_scale(const s: TVec3): TMat4;
function  m4_rot_axis(const axis: TVec3; const ang: Single): TMat4;
function  m4_from_quat(const q: TQuat): TMat4;
function  m4_compose(const pos: TVec3; const q: TQuat; const scl: TVec3): TMat4;
function  m4_perspective(fovy, aspect, znear, zfar: Single): TMat4;
function  m4_ortho(l, r, b, t, zn, zf: Single): TMat4;
function  m4_lookat(const eye, target, up: TVec3): TMat4;
function  m4_transform_point(const m: TMat4; const p: TVec3): TVec3; inline;
function  m4_transform_dir(const m: TMat4; const v: TVec3): TVec3; inline;
function  m4_inverse_affine(const m: TMat4): TMat4;
function  m4_transpose(const m: TMat4): TMat4;
function  m4_normal_matrix(const m: TMat4): TMat3;

{ --------------------------------------------------------------- кватернионы }
function  q_identity: TQuat; inline;
function  q_from_axis(const axis: TVec3; const ang: Single): TQuat;
function  q_from_euler(pitch, yaw, roll: Single): TQuat;
function  q_mul(const a, b: TQuat): TQuat; inline;
function  q_conj(const a: TQuat): TQuat; inline;
function  q_norm(const a: TQuat): TQuat;
function  q_rotate(const q: TQuat; const v: TVec3): TVec3; inline;
function  q_slerp(const a, b: TQuat; const t: Single): TQuat;
function  q_integrate(const q: TQuat; const w: TVec3; const dt: Single): TQuat;

{ ------------------------------------------------------------------ 3x3 }
function  m3_identity: TMat3;
function  m3_mul(const a, b: TMat3): TMat3;
function  m3_transpose(const a: TMat3): TMat3;
function  m3_mulv(const a: TMat3; const v: TVec3): TVec3; inline;
function  m3_from_quat(const q: TQuat): TMat3;
function  m3_scale(const a: TMat3; const s: Single): TMat3;
function  m3_inverse(const a: TMat3): TMat3;

{ ------------------------------------------------------------------ AABB }
function  aabb_empty: TAABB;
procedure aabb_add(var b: TAABB; const p: TVec3); inline;
function  aabb_overlap(const a, b: TAABB): Boolean; inline;
function  aabb_expand(const a: TAABB; const r: Single): TAABB; inline;
function  aabb_center(const a: TAABB): TVec3; inline;
function  aabb_contains(const a: TAABB; const p: TVec3): Boolean; inline;

{ ------------------------------------------------------------- плоскости }
function  plane_from_points(const a, b, c: TVec3): TPlane;
function  plane_dist(const pl: TPlane; const p: TVec3): Single; inline;
function  frustum_from_matrix(const vp: TMat4): TFrustum;
function  frustum_test_sphere(const f: TFrustum; const c: TVec3; r: Single): Boolean;
function  frustum_test_aabb(const f: TFrustum; const b: TAABB): Boolean;

{ ------------------------------------------------------------------ скаляры }
function  fclamp(const v, lo, hi: Single): Single; inline;
function  fmin(const a, b: Single): Single; inline;
function  fmax(const a, b: Single): Single; inline;
function  fsign(const a: Single): Single; inline;
function  flerp(const a, b, t: Single): Single; inline;
function  rsqrt(const x: Single): Single; inline;
function  rand_float: Single;
function  rand_range(const a, b: Single): Single;

implementation

uses
  Math;

{ =========================================================================
  Векторы
  ========================================================================= }

function v3(const ax, ay, az: Single): TVec3;
begin
  Result.x := ax; Result.y := ay; Result.z := az;
end;

function v4_make(const ax, ay, az, aw: Single): TVec4;
begin
  Result.x := ax; Result.y := ay; Result.z := az; Result.w := aw;
end;

function v3_zero: TVec3;
begin
  Result.x := 0; Result.y := 0; Result.z := 0;
end;

function v3_add(const a, b: TVec3): TVec3;
begin
  Result.x := a.x + b.x; Result.y := a.y + b.y; Result.z := a.z + b.z;
end;

function v3_sub(const a, b: TVec3): TVec3;
begin
  Result.x := a.x - b.x; Result.y := a.y - b.y; Result.z := a.z - b.z;
end;

function v3_mul(const a: TVec3; const s: Single): TVec3;
begin
  Result.x := a.x * s; Result.y := a.y * s; Result.z := a.z * s;
end;

function v3_mula(const a, b: TVec3): TVec3;
begin
  Result.x := a.x * b.x; Result.y := a.y * b.y; Result.z := a.z * b.z;
end;

function v3_neg(const a: TVec3): TVec3;
begin
  Result.x := -a.x; Result.y := -a.y; Result.z := -a.z;
end;

function v3_mad(const a, b: TVec3; const s: Single): TVec3;
begin
  Result.x := a.x + b.x * s;
  Result.y := a.y + b.y * s;
  Result.z := a.z + b.z * s;
end;

function v3_dot(const a, b: TVec3): Single;
begin
  Result := a.x * b.x + a.y * b.y + a.z * b.z;
end;

function v3_cross(const a, b: TVec3): TVec3;
begin
  Result.x := a.y * b.z - a.z * b.y;
  Result.y := a.z * b.x - a.x * b.z;
  Result.z := a.x * b.y - a.y * b.x;
end;

function v3_lensq(const a: TVec3): Single;
begin
  Result := a.x * a.x + a.y * a.y + a.z * a.z;
end;

function v3_len(const a: TVec3): Single;
begin
  Result := Sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
end;

function v3_distsq(const a, b: TVec3): Single;
var dx, dy, dz: Single;
begin
  dx := a.x - b.x; dy := a.y - b.y; dz := a.z - b.z;
  Result := dx * dx + dy * dy + dz * dz;
end;

function v3_dist(const a, b: TVec3): Single;
begin
  Result := Sqrt(v3_distsq(a, b));
end;

function v3_norm(const a: TVec3): TVec3;
var l: Single;
begin
  l := a.x * a.x + a.y * a.y + a.z * a.z;
  if l > EPS_SQR then
  begin
    l := 1.0 / Sqrt(l);
    Result.x := a.x * l; Result.y := a.y * l; Result.z := a.z * l;
  end
  else
  begin
    Result.x := 0; Result.y := 0; Result.z := 0;
  end;
end;

function v3_lerp(const a, b: TVec3; const t: Single): TVec3;
begin
  Result.x := a.x + (b.x - a.x) * t;
  Result.y := a.y + (b.y - a.y) * t;
  Result.z := a.z + (b.z - a.z) * t;
end;

function v3_min(const a, b: TVec3): TVec3;
begin
  if a.x < b.x then Result.x := a.x else Result.x := b.x;
  if a.y < b.y then Result.y := a.y else Result.y := b.y;
  if a.z < b.z then Result.z := a.z else Result.z := b.z;
end;

function v3_max(const a, b: TVec3): TVec3;
begin
  if a.x > b.x then Result.x := a.x else Result.x := b.x;
  if a.y > b.y then Result.y := a.y else Result.y := b.y;
  if a.z > b.z then Result.z := a.z else Result.z := b.z;
end;

function v3_abs(const a: TVec3): TVec3;
begin
  Result.x := Abs(a.x); Result.y := Abs(a.y); Result.z := Abs(a.z);
end;

function v3_maxcomp(const a: TVec3): Single;
begin
  Result := a.x;
  if a.y > Result then Result := a.y;
  if a.z > Result then Result := a.z;
end;

function v3_iszero(const a: TVec3): Boolean;
begin
  Result := v3_lensq(a) < EPS_SQR;
end;

function v3_reflect(const v, n: TVec3): TVec3;
begin
  Result := v3_mad(v, n, -2.0 * v3_dot(v, n));
end;

procedure v3_basis(const n: TVec3; out t1, t2: TVec3);
begin
  { Устойчивое построение ортонормированного базиса: выбираем ось,
    наименее параллельную n, чтобы не потерять точность. }
  if Abs(n.x) >= 0.57735 then
    t1 := v3_norm(v3(n.y, -n.x, 0))
  else
    t1 := v3_norm(v3(0, n.z, -n.y));
  t2 := v3_cross(n, t1);
end;

{ =========================================================================
  Матрицы 4x4 (column-major: m[col*4 + row])
  ========================================================================= }

function m4_identity: TMat4;
var i: Integer;
begin
  for i := 0 to 15 do Result.m[i] := 0;
  Result.m[0] := 1; Result.m[5] := 1; Result.m[10] := 1; Result.m[15] := 1;
end;

function m4_mul(const a, b: TMat4): TMat4;
var
  c, r: Integer;
  b0, b1, b2, b3: Single;
begin
  { Колоночный порядок обхода: столбец b читается один раз в регистры,
    строки a идут последовательно -- дружелюбно к кэшу и к автовекторизации. }
  for c := 0 to 3 do
  begin
    b0 := b.m[c * 4 + 0];
    b1 := b.m[c * 4 + 1];
    b2 := b.m[c * 4 + 2];
    b3 := b.m[c * 4 + 3];
    for r := 0 to 3 do
      Result.m[c * 4 + r] :=
        a.m[0 + r] * b0 + a.m[4 + r] * b1 + a.m[8 + r] * b2 + a.m[12 + r] * b3;
  end;
end;

function m4_translate(const t: TVec3): TMat4;
begin
  Result := m4_identity;
  Result.m[12] := t.x; Result.m[13] := t.y; Result.m[14] := t.z;
end;

function m4_scale(const s: TVec3): TMat4;
begin
  Result := m4_identity;
  Result.m[0] := s.x; Result.m[5] := s.y; Result.m[10] := s.z;
end;

function m4_from_quat(const q: TQuat): TMat4;
var
  xx, yy, zz, xy, xz, yz, wx, wy, wz: Single;
begin
  xx := q.x * q.x; yy := q.y * q.y; zz := q.z * q.z;
  xy := q.x * q.y; xz := q.x * q.z; yz := q.y * q.z;
  wx := q.w * q.x; wy := q.w * q.y; wz := q.w * q.z;

  Result.m[0]  := 1 - 2 * (yy + zz);
  Result.m[1]  := 2 * (xy + wz);
  Result.m[2]  := 2 * (xz - wy);
  Result.m[3]  := 0;

  Result.m[4]  := 2 * (xy - wz);
  Result.m[5]  := 1 - 2 * (xx + zz);
  Result.m[6]  := 2 * (yz + wx);
  Result.m[7]  := 0;

  Result.m[8]  := 2 * (xz + wy);
  Result.m[9]  := 2 * (yz - wx);
  Result.m[10] := 1 - 2 * (xx + yy);
  Result.m[11] := 0;

  Result.m[12] := 0; Result.m[13] := 0; Result.m[14] := 0; Result.m[15] := 1;
end;

function m4_rot_axis(const axis: TVec3; const ang: Single): TMat4;
begin
  Result := m4_from_quat(q_from_axis(axis, ang));
end;

function m4_compose(const pos: TVec3; const q: TQuat; const scl: TVec3): TMat4;
begin
  Result := m4_from_quat(q);
  Result.m[0] := Result.m[0] * scl.x;
  Result.m[1] := Result.m[1] * scl.x;
  Result.m[2] := Result.m[2] * scl.x;
  Result.m[4] := Result.m[4] * scl.y;
  Result.m[5] := Result.m[5] * scl.y;
  Result.m[6] := Result.m[6] * scl.y;
  Result.m[8] := Result.m[8] * scl.z;
  Result.m[9] := Result.m[9] * scl.z;
  Result.m[10] := Result.m[10] * scl.z;
  Result.m[12] := pos.x; Result.m[13] := pos.y; Result.m[14] := pos.z;
end;

function m4_perspective(fovy, aspect, znear, zfar: Single): TMat4;
var
  f, nf: Single;
  i: Integer;
begin
  for i := 0 to 15 do Result.m[i] := 0;
  f := 1.0 / Tan(fovy * 0.5);
  nf := 1.0 / (znear - zfar);
  Result.m[0]  := f / aspect;
  Result.m[5]  := f;
  Result.m[10] := (zfar + znear) * nf;
  Result.m[11] := -1;
  Result.m[14] := 2 * zfar * znear * nf;
end;

function m4_ortho(l, r, b, t, zn, zf: Single): TMat4;
begin
  Result := m4_identity;
  Result.m[0]  := 2 / (r - l);
  Result.m[5]  := 2 / (t - b);
  Result.m[10] := -2 / (zf - zn);
  Result.m[12] := -(r + l) / (r - l);
  Result.m[13] := -(t + b) / (t - b);
  Result.m[14] := -(zf + zn) / (zf - zn);
end;

function m4_lookat(const eye, target, up: TVec3): TMat4;
var
  f, s, u: TVec3;
begin
  f := v3_norm(v3_sub(target, eye));
  s := v3_norm(v3_cross(f, up));
  u := v3_cross(s, f);

  Result.m[0] := s.x; Result.m[1] := u.x; Result.m[2] := -f.x; Result.m[3] := 0;
  Result.m[4] := s.y; Result.m[5] := u.y; Result.m[6] := -f.y; Result.m[7] := 0;
  Result.m[8] := s.z; Result.m[9] := u.z; Result.m[10] := -f.z; Result.m[11] := 0;
  Result.m[12] := -v3_dot(s, eye);
  Result.m[13] := -v3_dot(u, eye);
  Result.m[14] :=  v3_dot(f, eye);
  Result.m[15] := 1;
end;

function m4_transform_point(const m: TMat4; const p: TVec3): TVec3;
begin
  Result.x := m.m[0] * p.x + m.m[4] * p.y + m.m[8]  * p.z + m.m[12];
  Result.y := m.m[1] * p.x + m.m[5] * p.y + m.m[9]  * p.z + m.m[13];
  Result.z := m.m[2] * p.x + m.m[6] * p.y + m.m[10] * p.z + m.m[14];
end;

function m4_transform_dir(const m: TMat4; const v: TVec3): TVec3;
begin
  Result.x := m.m[0] * v.x + m.m[4] * v.y + m.m[8]  * v.z;
  Result.y := m.m[1] * v.x + m.m[5] * v.y + m.m[9]  * v.z;
  Result.z := m.m[2] * v.x + m.m[6] * v.y + m.m[10] * v.z;
end;

function m4_transpose(const m: TMat4): TMat4;
var r, c: Integer;
begin
  for c := 0 to 3 do
    for r := 0 to 3 do
      Result.m[c * 4 + r] := m.m[r * 4 + c];
end;

function m4_inverse_affine(const m: TMat4): TMat4;
var
  t: TVec3;
begin
  { Быстрая инверсия для матрицы "поворот + перенос": поворот
    транспонируем, перенос переносим с обратным знаком. }
  Result := m4_identity;
  Result.m[0] := m.m[0]; Result.m[1] := m.m[4]; Result.m[2]  := m.m[8];
  Result.m[4] := m.m[1]; Result.m[5] := m.m[5]; Result.m[6]  := m.m[9];
  Result.m[8] := m.m[2]; Result.m[9] := m.m[6]; Result.m[10] := m.m[10];
  t := v3(m.m[12], m.m[13], m.m[14]);
  Result.m[12] := -(Result.m[0] * t.x + Result.m[4] * t.y + Result.m[8]  * t.z);
  Result.m[13] := -(Result.m[1] * t.x + Result.m[5] * t.y + Result.m[9]  * t.z);
  Result.m[14] := -(Result.m[2] * t.x + Result.m[6] * t.y + Result.m[10] * t.z);
end;

function m4_normal_matrix(const m: TMat4): TMat3;
var a: TMat3;
begin
  a.m[0] := m.m[0]; a.m[1] := m.m[1]; a.m[2] := m.m[2];
  a.m[3] := m.m[4]; a.m[4] := m.m[5]; a.m[5] := m.m[6];
  a.m[6] := m.m[8]; a.m[7] := m.m[9]; a.m[8] := m.m[10];
  Result := m3_transpose(m3_inverse(a));
end;

{ =========================================================================
  Матрицы 3x3
  ========================================================================= }

function m3_identity: TMat3;
var i: Integer;
begin
  for i := 0 to 8 do Result.m[i] := 0;
  Result.m[0] := 1; Result.m[4] := 1; Result.m[8] := 1;
end;

function m3_mul(const a, b: TMat3): TMat3;
var c, r: Integer;
begin
  for c := 0 to 2 do
    for r := 0 to 2 do
      Result.m[c * 3 + r] := a.m[r] * b.m[c * 3] +
                             a.m[3 + r] * b.m[c * 3 + 1] +
                             a.m[6 + r] * b.m[c * 3 + 2];
end;

function m3_transpose(const a: TMat3): TMat3;
var r, c: Integer;
begin
  for c := 0 to 2 do
    for r := 0 to 2 do
      Result.m[c * 3 + r] := a.m[r * 3 + c];
end;

function m3_mulv(const a: TMat3; const v: TVec3): TVec3;
begin
  Result.x := a.m[0] * v.x + a.m[3] * v.y + a.m[6] * v.z;
  Result.y := a.m[1] * v.x + a.m[4] * v.y + a.m[7] * v.z;
  Result.z := a.m[2] * v.x + a.m[5] * v.y + a.m[8] * v.z;
end;

function m3_from_quat(const q: TQuat): TMat3;
var m: TMat4;
begin
  m := m4_from_quat(q);
  Result.m[0] := m.m[0]; Result.m[1] := m.m[1]; Result.m[2] := m.m[2];
  Result.m[3] := m.m[4]; Result.m[4] := m.m[5]; Result.m[5] := m.m[6];
  Result.m[6] := m.m[8]; Result.m[7] := m.m[9]; Result.m[8] := m.m[10];
end;

function m3_scale(const a: TMat3; const s: Single): TMat3;
var i: Integer;
begin
  for i := 0 to 8 do Result.m[i] := a.m[i] * s;
end;

function m3_inverse(const a: TMat3): TMat3;
var
  c0, c1, c2, det, inv: Single;
begin
  c0 := a.m[4] * a.m[8] - a.m[7] * a.m[5];
  c1 := a.m[7] * a.m[2] - a.m[1] * a.m[8];
  c2 := a.m[1] * a.m[5] - a.m[4] * a.m[2];
  det := a.m[0] * c0 + a.m[3] * c1 + a.m[6] * c2;
  if Abs(det) < 1.0e-20 then
  begin
    Result := m3_identity;
    Exit;
  end;
  inv := 1.0 / det;
  Result.m[0] := c0 * inv;
  Result.m[1] := c1 * inv;
  Result.m[2] := c2 * inv;
  Result.m[3] := (a.m[6] * a.m[5] - a.m[3] * a.m[8]) * inv;
  Result.m[4] := (a.m[0] * a.m[8] - a.m[6] * a.m[2]) * inv;
  Result.m[5] := (a.m[3] * a.m[2] - a.m[0] * a.m[5]) * inv;
  Result.m[6] := (a.m[3] * a.m[7] - a.m[6] * a.m[4]) * inv;
  Result.m[7] := (a.m[6] * a.m[1] - a.m[0] * a.m[7]) * inv;
  Result.m[8] := (a.m[0] * a.m[4] - a.m[3] * a.m[1]) * inv;
end;

{ =========================================================================
  Кватернионы
  ========================================================================= }

function q_identity: TQuat;
begin
  Result.x := 0; Result.y := 0; Result.z := 0; Result.w := 1;
end;

function q_from_axis(const axis: TVec3; const ang: Single): TQuat;
var
  a: TVec3;
  s, h: Single;
begin
  a := v3_norm(axis);
  h := ang * 0.5;
  s := Sin(h);
  Result.x := a.x * s; Result.y := a.y * s; Result.z := a.z * s;
  Result.w := Cos(h);
end;

function q_from_euler(pitch, yaw, roll: Single): TQuat;
var
  cp, sp, cy, sy, cr, sr: Single;
begin
  cp := Cos(pitch * 0.5); sp := Sin(pitch * 0.5);
  cy := Cos(yaw   * 0.5); sy := Sin(yaw   * 0.5);
  cr := Cos(roll  * 0.5); sr := Sin(roll  * 0.5);
  Result.w := cr * cp * cy + sr * sp * sy;
  Result.x := cr * sp * cy + sr * cp * sy;
  Result.y := cr * cp * sy - sr * sp * cy;
  Result.z := sr * cp * cy - cr * sp * sy;
end;

function q_mul(const a, b: TQuat): TQuat;
begin
  Result.x := a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y;
  Result.y := a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x;
  Result.z := a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w;
  Result.w := a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
end;

function q_conj(const a: TQuat): TQuat;
begin
  Result.x := -a.x; Result.y := -a.y; Result.z := -a.z; Result.w := a.w;
end;

function q_norm(const a: TQuat): TQuat;
var l: Single;
begin
  l := a.x * a.x + a.y * a.y + a.z * a.z + a.w * a.w;
  if l > EPS_SQR then
  begin
    l := 1.0 / Sqrt(l);
    Result.x := a.x * l; Result.y := a.y * l;
    Result.z := a.z * l; Result.w := a.w * l;
  end
  else
    Result := q_identity;
end;

function q_rotate(const q: TQuat; const v: TVec3): TVec3;
var
  u, t: TVec3;
begin
  { v' = v + 2w(u x v) + 2(u x (u x v)) -- дешевле, чем строить матрицу }
  u := v3(q.x, q.y, q.z);
  t := v3_mul(v3_cross(u, v), 2.0);
  Result := v3_add(v3_mad(v, t, q.w), v3_cross(u, t));
end;

function q_slerp(const a, b: TQuat; const t: Single): TQuat;
var
  cosom, sinom, omega, s0, s1: Single;
  bb: TQuat;
begin
  bb := b;
  cosom := a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  if cosom < 0 then
  begin
    cosom := -cosom;
    bb.x := -b.x; bb.y := -b.y; bb.z := -b.z; bb.w := -b.w;
  end;
  if cosom > 0.9995 then
  begin
    s0 := 1 - t; s1 := t;
  end
  else
  begin
    omega := ArcCos(cosom);
    sinom := Sin(omega);
    s0 := Sin((1 - t) * omega) / sinom;
    s1 := Sin(t * omega) / sinom;
  end;
  Result.x := a.x * s0 + bb.x * s1;
  Result.y := a.y * s0 + bb.y * s1;
  Result.z := a.z * s0 + bb.z * s1;
  Result.w := a.w * s0 + bb.w * s1;
  Result := q_norm(Result);
end;

function q_integrate(const q: TQuat; const w: TVec3; const dt: Single): TQuat;
var
  wq, dq: TQuat;
  h: Single;
begin
  h := dt * 0.5;
  wq.x := w.x; wq.y := w.y; wq.z := w.z; wq.w := 0;
  dq := q_mul(wq, q);
  Result.x := q.x + dq.x * h;
  Result.y := q.y + dq.y * h;
  Result.z := q.z + dq.z * h;
  Result.w := q.w + dq.w * h;
  Result := q_norm(Result);
end;

{ =========================================================================
  AABB
  ========================================================================= }

function aabb_empty: TAABB;
begin
  Result.mn := v3( 1.0e30,  1.0e30,  1.0e30);
  Result.mx := v3(-1.0e30, -1.0e30, -1.0e30);
end;

procedure aabb_add(var b: TAABB; const p: TVec3);
begin
  b.mn := v3_min(b.mn, p);
  b.mx := v3_max(b.mx, p);
end;

function aabb_overlap(const a, b: TAABB): Boolean;
begin
  Result := (a.mn.x <= b.mx.x) and (a.mx.x >= b.mn.x) and
            (a.mn.y <= b.mx.y) and (a.mx.y >= b.mn.y) and
            (a.mn.z <= b.mx.z) and (a.mx.z >= b.mn.z);
end;

function aabb_expand(const a: TAABB; const r: Single): TAABB;
begin
  Result.mn := v3(a.mn.x - r, a.mn.y - r, a.mn.z - r);
  Result.mx := v3(a.mx.x + r, a.mx.y + r, a.mx.z + r);
end;

function aabb_center(const a: TAABB): TVec3;
begin
  Result := v3_mul(v3_add(a.mn, a.mx), 0.5);
end;

function aabb_contains(const a: TAABB; const p: TVec3): Boolean;
begin
  Result := (p.x >= a.mn.x) and (p.x <= a.mx.x) and
            (p.y >= a.mn.y) and (p.y <= a.mx.y) and
            (p.z >= a.mn.z) and (p.z <= a.mx.z);
end;

{ =========================================================================
  Плоскости и пирамида видимости
  ========================================================================= }

function plane_from_points(const a, b, c: TVec3): TPlane;
begin
  Result.n := v3_norm(v3_cross(v3_sub(b, a), v3_sub(c, a)));
  Result.d := -v3_dot(Result.n, a);
end;

function plane_dist(const pl: TPlane; const p: TVec3): Single;
begin
  Result := v3_dot(pl.n, p) + pl.d;
end;

procedure normalize_plane(var p: TPlane);
var l: Single;
begin
  l := v3_len(p.n);
  if l > EPS then
  begin
    l := 1.0 / l;
    p.n := v3_mul(p.n, l);
    p.d := p.d * l;
  end;
end;

function frustum_from_matrix(const vp: TMat4): TFrustum;
var i: Integer;
begin
  { Метод Gribb/Hartmann: плоскости извлекаются прямо из матрицы
    view-projection сложением/вычитанием её строк. }
  Result.p[0].n := v3(vp.m[3] + vp.m[0], vp.m[7] + vp.m[4], vp.m[11] + vp.m[8]);
  Result.p[0].d := vp.m[15] + vp.m[12];
  Result.p[1].n := v3(vp.m[3] - vp.m[0], vp.m[7] - vp.m[4], vp.m[11] - vp.m[8]);
  Result.p[1].d := vp.m[15] - vp.m[12];
  Result.p[2].n := v3(vp.m[3] + vp.m[1], vp.m[7] + vp.m[5], vp.m[11] + vp.m[9]);
  Result.p[2].d := vp.m[15] + vp.m[13];
  Result.p[3].n := v3(vp.m[3] - vp.m[1], vp.m[7] - vp.m[5], vp.m[11] - vp.m[9]);
  Result.p[3].d := vp.m[15] - vp.m[13];
  Result.p[4].n := v3(vp.m[3] + vp.m[2], vp.m[7] + vp.m[6], vp.m[11] + vp.m[10]);
  Result.p[4].d := vp.m[15] + vp.m[14];
  Result.p[5].n := v3(vp.m[3] - vp.m[2], vp.m[7] - vp.m[6], vp.m[11] - vp.m[10]);
  Result.p[5].d := vp.m[15] - vp.m[14];
  for i := 0 to 5 do normalize_plane(Result.p[i]);
end;

function frustum_test_sphere(const f: TFrustum; const c: TVec3; r: Single): Boolean;
var i: Integer;
begin
  for i := 0 to 5 do
    if plane_dist(f.p[i], c) < -r then
    begin
      Result := False;
      Exit;
    end;
  Result := True;
end;

function frustum_test_aabb(const f: TFrustum; const b: TAABB): Boolean;
var
  i: Integer;
  c, e: TVec3;
  r, s: Single;
begin
  c := v3_mul(v3_add(b.mn, b.mx), 0.5);
  e := v3_mul(v3_sub(b.mx, b.mn), 0.5);
  for i := 0 to 5 do
  begin
    r := e.x * Abs(f.p[i].n.x) + e.y * Abs(f.p[i].n.y) + e.z * Abs(f.p[i].n.z);
    s := plane_dist(f.p[i], c);
    if s < -r then
    begin
      Result := False;
      Exit;
    end;
  end;
  Result := True;
end;

{ =========================================================================
  Скаляры
  ========================================================================= }

function fclamp(const v, lo, hi: Single): Single;
begin
  if v < lo then Result := lo
  else if v > hi then Result := hi
  else Result := v;
end;

function fmin(const a, b: Single): Single;
begin
  if a < b then Result := a else Result := b;
end;

function fmax(const a, b: Single): Single;
begin
  if a > b then Result := a else Result := b;
end;

function fsign(const a: Single): Single;
begin
  if a < 0 then Result := -1 else Result := 1;
end;

function flerp(const a, b, t: Single): Single;
begin
  Result := a + (b - a) * t;
end;

function rsqrt(const x: Single): Single;
begin
  if x > EPS_SQR then Result := 1.0 / Sqrt(x) else Result := 0;
end;

var
  g_rand_state: Cardinal = 2463534242;

function rand_float: Single;
begin
  { xorshift32 -- быстрый и достаточный для игровой логики ГПСЧ }
  g_rand_state := g_rand_state xor (g_rand_state shl 13);
  g_rand_state := g_rand_state xor (g_rand_state shr 17);
  g_rand_state := g_rand_state xor (g_rand_state shl 5);
  Result := (g_rand_state shr 8) * (1.0 / 16777216.0);
end;

function rand_range(const a, b: Single): Single;
begin
  Result := a + (b - a) * rand_float;
end;

end.
