{ ============================================================================
  hdeh-math - vectors, matrices, bounding volumes, noise.

  This unit is the mathematical foundation of the hdeh 3D engine.  It has no
  dependencies except the FPC RTL and works on "Single" precision floats.

  Conventions used everywhere in hdeh:

    * Right handed coordinate system, +Y is up, the camera looks down -Z in
      view space (the same convention used by OpenGL).
    * A 4x4 matrix is stored column major: element at (row R, column C) lives
      in M[C, R].  A point is transformed as  v' = M * v  (v is a column
      vector), exactly like OpenGL.
    * Angles passed to the Mat4* helpers are in degrees, everything else
      (FovY, shadows, fog) is documented at the place of use.
    * Projection matrices map the view frustum to the OpenGL clip cube,
      i.e. NDC z is in [-1, 1].  The rasterizer converts that to [0, 1]
      for the depth buffer.
  ============================================================================ }
unit hdeh_math;
{$mode objfpc}{$H+}

interface

uses
  Math;

type
  TVec2 = record
    X, Y: Single;
  end;

  TVec3 = record
    X, Y, Z: Single;
  end;

  TVec4 = record
    X, Y, Z, W: Single;
  end;

  // column major 4x4 matrix, M[column, row]
  TMat4 = record
    M: array[0..3, 0..3] of Single;
  end;

  // axis aligned bounding box
  TAABB = record
    Min, Max: TVec3;
    Valid: Boolean;
  end;

  // view frustum as six planes (x,y,z = normal, w = distance)
  TFrustum = record
    Planes: array[0..5] of TVec4;
  end;

const
  Vec2Zero: TVec2 = (X: 0; Y: 0);
  Vec3Zero: TVec3 = (X: 0; Y: 0; Z: 0);
  Vec3One : TVec3 = (X: 1; Y: 1; Z: 1);
  Vec3UnitX: TVec3 = (X: 1; Y: 0; Z: 0);
  Vec3UnitY: TVec3 = (X: 0; Y: 1; Z: 0);
  Vec3UnitZ: TVec3 = (X: 0; Y: 0; Z: 1);

  IdentityMat4: TMat4 = (M: ((1, 0, 0, 0),
                              (0, 1, 0, 0),
                              (0, 0, 1, 0),
                              (0, 0, 0, 1)));

{ ---------------------------------------------------------------- scalars -- }
function MinS(A, B: Single): Single; inline;
function MaxS(A, B: Single): Single; inline;
function ClampS(V, Lo, Hi: Single): Single; inline;
function ClampI(V, Lo, Hi: LongInt): LongInt; inline;
function LerpS(A, B, T: Single): Single; inline;
function SmoothStepS(A, B, X: Single): Single;
function StepS(Edge, X: Single): Single; inline;
function SignS(V: Single): Single; inline;
function FracS(V: Single): Single; inline;
function Saturate(V: Single): Single; inline;

{ ------------------------------------------------------------------ vec2 -- }
function Vec2(AX, AY: Single): TVec2; inline;
function Vec2Add(const A, B: TVec2): TVec2; inline;
function Vec2Sub(const A, B: TVec2): TVec2; inline;

{ ------------------------------------------------------------------ vec3 -- }
function Vec3(AX, AY, AZ: Single): TVec3; inline;
function Vec3Add(const A, B: TVec3): TVec3; inline;
function Vec3Sub(const A, B: TVec3): TVec3; inline;
function Vec3Scale(const A: TVec3; S: Single): TVec3; inline;
function Vec3Mul(const A, B: TVec3): TVec3; inline;
function Vec3Dot(const A, B: TVec3): Single; inline;
function Vec3Cross(const A, B: TVec3): TVec3; inline;
function Vec3LengthSq(const A: TVec3): Single; inline;
function Vec3Length(const A: TVec3): Single;
function Vec3Distance(const A, B: TVec3): Single;
function Vec3DistanceSq(const A, B: TVec3): Single;
function Vec3Normalize(const A: TVec3): TVec3;
function Vec3Lerp(const A, B: TVec3; T: Single): TVec3; inline;
function Vec3Reflect(const I, N: TVec3): TVec3;
function Vec3Min(const A, B: TVec3): TVec3;
function Vec3Max(const A, B: TVec3): TVec3;
function Vec3Abs(const A: TVec3): TVec3;
function Vec3Neg(const A: TVec3): TVec3; inline;
function Vec3FaceForward(const N, Towards: TVec3): TVec3;
function Vec3FromVec2(const A: TVec2; Z: Single): TVec3; inline;

{ ------------------------------------------------------------------ vec4 -- }
function Vec4(AX, AY, AZ, AW: Single): TVec4; inline;
function Vec4FromVec3(const A: TVec3; AW: Single): TVec4; inline;
function Vec4ToVec3(const A: TVec4): TVec3; inline;
function Vec4Add(const A, B: TVec4): TVec4; inline;
function Vec4Sub(const A, B: TVec4): TVec4; inline;
function Vec4Scale(const A: TVec4; S: Single): TVec4; inline;
function Vec4Dot(const A, B: TVec4): Single; inline;
function Vec4Lerp(const A, B: TVec4; T: Single): TVec4; inline;

{ ---------------------------------------------------------------- mat4 ---- }
function Mat4Identity: TMat4; inline;
function Mat4Translation(const T: TVec3): TMat4; inline;
function Mat4Scale(const S: TVec3): TMat4; inline;
function Mat4ScaleUniform(S: Single): TMat4; inline;
function Mat4RotationX(AngleDeg: Single): TMat4;
function Mat4RotationY(AngleDeg: Single): TMat4;
function Mat4RotationZ(AngleDeg: Single): TMat4;
function Mat4RotationAxis(const Axis: TVec3; AngleDeg: Single): TMat4;
function Mat4LookAt(const Eye, Target, Up: TVec3): TMat4;
function Mat4Perspective(FovYDeg, Aspect, ZNear, ZFar: Single): TMat4;
function Mat4Ortho(Left, Right, Bottom, Top, ZNear, ZFar: Single): TMat4;
function Mat4Inverse(const M: TMat4): TMat4;
function Mat4Transpose(const M: TMat4): TMat4;
function Mat4NormalMatrix(const M: TMat4): TMat4;
function Mat4Compose(const Pos, RotDeg, Scale: TVec3): TMat4;
function Mat4Column(const M: TMat4; Index: LongInt): TVec4;
function Mat4FromColumns(const C0, C1, C2, C3: TVec4): TMat4;
function Mat4MulPoint(const M: TMat4; const P: TVec3): TVec3;
function Mat4MulPoint4(const M: TMat4; const P: TVec3): TVec4;
function Mat4MulDir(const M: TMat4; const D: TVec3): TVec3;
function Mat4GetTranslation(const M: TMat4): TVec3; inline;
function Mat4Determinant3(const M: TMat4): Single;

{ ---------------------------------------------------------------- aabb ---- }
function AABBEmpty: TAABB;
function AABBFromPoints(const A, B: TVec3): TAABB;
function AABBUnion(const A, B: TAABB): TAABB;
function AABBExpand(const A: TAABB; Point: TVec3): TAABB;
function AABBCenter(const B: TAABB): TVec3;
function AABBExtents(const B: TAABB): TVec3;
function AABBRadius(const B: TAABB): Single;
function AABBTransform(const B: TAABB; const M: TMat4): TAABB;
function AABBContainsPoint(const B: TAABB; const P: TVec3): Boolean;

{ -------------------------------------------------------------- frustum --- }
function FrustumFromViewProj(const M: TMat4): TFrustum;
function FrustumTestPoint(const F: TFrustum; const P: TVec3): Boolean;
function FrustumTestSphere(const F: TFrustum; const C: TVec3; Radius: Single): Boolean;
function FrustumTestAABB(const F: TFrustum; const B: TAABB): Boolean;

{ --------------------------------------------------------------- random --- }
function RandomNext(var State: QWord): QWord; inline;
function RandomFloat(var State: QWord): Single;      // [0, 1)
function RandomRange(var State: QWord; A, B: Single): Single;
function Hash3(Seed: LongWord; X, Y, Z: LongInt): LongWord;

{ ---------------------------------------------------------------- noise --- }
function Noise2D(X, Y: Single; Seed: LongWord): Single;        // value noise, [0,1]
function FBM2D(X, Y: Single; Octaves: LongInt; Seed: LongWord): Single;
function Noise3D(X, Y, Z: Single; Seed: LongWord): Single;

{ ------------------------------------------------------------ operators --- }
operator + (const A, B: TVec2) R: TVec2;
operator - (const A, B: TVec2) R: TVec2;
operator * (const A: TVec2; S: Single) R: TVec2;

operator + (const A, B: TVec3) R: TVec3;
operator - (const A, B: TVec3) R: TVec3;
operator - (const A: TVec3) R: TVec3;
operator * (const A: TVec3; S: Single) R: TVec3;
operator * (S: Single; const A: TVec3) R: TVec3;
operator / (const A: TVec3; S: Single) R: TVec3;

operator + (const A, B: TVec4) R: TVec4;
operator * (const A: TVec4; S: Single) R: TVec4;

operator * (const A, B: TMat4) R: TMat4;
operator * (const A: TMat4; const V: TVec4) R: TVec4;

implementation

{ ================================================================ scalars == }

function MinS(A, B: Single): Single;
begin
  if A < B then Result := A else Result := B;
end;

function MaxS(A, B: Single): Single;
begin
  if A > B then Result := A else Result := B;
end;

function ClampS(V, Lo, Hi: Single): Single;
begin
  if V < Lo then Result := Lo
  else if V > Hi then Result := Hi
  else Result := V;
end;

function ClampI(V, Lo, Hi: LongInt): LongInt;
begin
  if V < Lo then Result := Lo
  else if V > Hi then Result := Hi
  else Result := V;
end;

function LerpS(A, B, T: Single): Single;
begin
  Result := A + (B - A) * T;
end;

function SmoothStepS(A, B, X: Single): Single;
var
  T: Single;
begin
  if B = A then
    begin
      if X < A then Result := 0 else Result := 1;
      Exit;
    end;
  T := ClampS((X - A) / (B - A), 0, 1);
  Result := T * T * (3 - 2 * T);
end;

function StepS(Edge, X: Single): Single;
begin
  if X < Edge then Result := 0 else Result := 1;
end;

function SignS(V: Single): Single;
begin
  if V > 0 then Result := 1
  else if V < 0 then Result := -1
  else Result := 0;
end;

function FracS(V: Single): Single;
begin
  Result := V - Int(V);
end;

function Saturate(V: Single): Single;
begin
  Result := ClampS(V, 0, 1);
end;

{ =================================================================== vec2 == }

function Vec2(AX, AY: Single): TVec2;
begin
  Result.X := AX;
  Result.Y := AY;
end;

function Vec2Add(const A, B: TVec2): TVec2;
begin
  Result.X := A.X + B.X;
  Result.Y := A.Y + B.Y;
end;

function Vec2Sub(const A, B: TVec2): TVec2;
begin
  Result.X := A.X - B.X;
  Result.Y := A.Y - B.Y;
end;

{ =================================================================== vec3 == }

function Vec3(AX, AY, AZ: Single): TVec3;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Z := AZ;
end;

function Vec3Add(const A, B: TVec3): TVec3;
begin
  Result.X := A.X + B.X;
  Result.Y := A.Y + B.Y;
  Result.Z := A.Z + B.Z;
end;

function Vec3Sub(const A, B: TVec3): TVec3;
begin
  Result.X := A.X - B.X;
  Result.Y := A.Y - B.Y;
  Result.Z := A.Z - B.Z;
end;

function Vec3Scale(const A: TVec3; S: Single): TVec3;
begin
  Result.X := A.X * S;
  Result.Y := A.Y * S;
  Result.Z := A.Z * S;
end;

function Vec3Mul(const A, B: TVec3): TVec3;
begin
  Result.X := A.X * B.X;
  Result.Y := A.Y * B.Y;
  Result.Z := A.Z * B.Z;
end;

function Vec3Dot(const A, B: TVec3): Single;
begin
  Result := A.X * B.X + A.Y * B.Y + A.Z * B.Z;
end;

function Vec3Cross(const A, B: TVec3): TVec3;
begin
  Result.X := A.Y * B.Z - A.Z * B.Y;
  Result.Y := A.Z * B.X - A.X * B.Z;
  Result.Z := A.X * B.Y - A.Y * B.X;
end;

function Vec3LengthSq(const A: TVec3): Single;
begin
  Result := A.X * A.X + A.Y * A.Y + A.Z * A.Z;
end;

function Vec3Length(const A: TVec3): Single;
begin
  Result := Sqrt(Vec3LengthSq(A));
end;

function Vec3Distance(const A, B: TVec3): Single;
begin
  Result := Vec3Length(Vec3Sub(A, B));
end;

function Vec3DistanceSq(const A, B: TVec3): Single;
begin
  Result := Vec3LengthSq(Vec3Sub(A, B));
end;

function Vec3Normalize(const A: TVec3): TVec3;
var
  L: Single;
begin
  L := Vec3Length(A);
  if L > 1E-20 then
    begin
      Result.X := A.X / L;
      Result.Y := A.Y / L;
      Result.Z := A.Z / L;
    end
  else
    begin
      Result.X := 0;
      Result.Y := 0;
      Result.Z := 0;
    end;
end;

function Vec3Lerp(const A, B: TVec3; T: Single): TVec3;
begin
  Result.X := A.X + (B.X - A.X) * T;
  Result.Y := A.Y + (B.Y - A.Y) * T;
  Result.Z := A.Z + (B.Z - A.Z) * T;
end;

function Vec3Reflect(const I, N: TVec3): TVec3;
var
  D: Single;
begin
  D := 2 * Vec3Dot(I, N);
  Result.X := I.X - D * N.X;
  Result.Y := I.Y - D * N.Y;
  Result.Z := I.Z - D * N.Z;
end;

function Vec3Min(const A, B: TVec3): TVec3;
begin
  Result.X := MinS(A.X, B.X);
  Result.Y := MinS(A.Y, B.Y);
  Result.Z := MinS(A.Z, B.Z);
end;

function Vec3Max(const A, B: TVec3): TVec3;
begin
  Result.X := MaxS(A.X, B.X);
  Result.Y := MaxS(A.Y, B.Y);
  Result.Z := MaxS(A.Z, B.Z);
end;

function Vec3Abs(const A: TVec3): TVec3;
begin
  Result.X := Abs(A.X);
  Result.Y := Abs(A.Y);
  Result.Z := Abs(A.Z);
end;

function Vec3Neg(const A: TVec3): TVec3;
begin
  Result.X := -A.X;
  Result.Y := -A.Y;
  Result.Z := -A.Z;
end;

function Vec3FaceForward(const N, Towards: TVec3): TVec3;
begin
  if Vec3Dot(N, Towards) > 0 then
    Result := Vec3Neg(N)
  else
    Result := N;
end;

function Vec3FromVec2(const A: TVec2; Z: Single): TVec3;
begin
  Result.X := A.X;
  Result.Y := A.Y;
  Result.Z := Z;
end;

{ =================================================================== vec4 == }

function Vec4(AX, AY, AZ, AW: Single): TVec4;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Z := AZ;
  Result.W := AW;
end;

function Vec4FromVec3(const A: TVec3; AW: Single): TVec4;
begin
  Result.X := A.X;
  Result.Y := A.Y;
  Result.Z := A.Z;
  Result.W := AW;
end;

function Vec4ToVec3(const A: TVec4): TVec3;
begin
  Result.X := A.X;
  Result.Y := A.Y;
  Result.Z := A.Z;
end;

function Vec4Add(const A, B: TVec4): TVec4;
begin
  Result.X := A.X + B.X;
  Result.Y := A.Y + B.Y;
  Result.Z := A.Z + B.Z;
  Result.W := A.W + B.W;
end;

function Vec4Sub(const A, B: TVec4): TVec4;
begin
  Result.X := A.X - B.X;
  Result.Y := A.Y - B.Y;
  Result.Z := A.Z - B.Z;
  Result.W := A.W - B.W;
end;

function Vec4Scale(const A: TVec4; S: Single): TVec4;
begin
  Result.X := A.X * S;
  Result.Y := A.Y * S;
  Result.Z := A.Z * S;
  Result.W := A.W * S;
end;

function Vec4Dot(const A, B: TVec4): Single;
begin
  Result := A.X * B.X + A.Y * B.Y + A.Z * B.Z + A.W * B.W;
end;

function Vec4Lerp(const A, B: TVec4; T: Single): TVec4;
begin
  Result.X := A.X + (B.X - A.X) * T;
  Result.Y := A.Y + (B.Y - A.Y) * T;
  Result.Z := A.Z + (B.Z - A.Z) * T;
  Result.W := A.W + (B.W - A.W) * T;
end;

{ =================================================================== mat4 == }

function Mat4Identity: TMat4;
var
  C, R: LongInt;
begin
  for C := 0 to 3 do
    for R := 0 to 3 do
      if C = R then Result.M[C, R] := 1 else Result.M[C, R] := 0;
end;

function Mat4Translation(const T: TVec3): TMat4;
begin
  Result := Mat4Identity;
  Result.M[3, 0] := T.X;
  Result.M[3, 1] := T.Y;
  Result.M[3, 2] := T.Z;
end;

function Mat4Scale(const S: TVec3): TMat4;
begin
  Result := Mat4Identity;
  Result.M[0, 0] := S.X;
  Result.M[1, 1] := S.Y;
  Result.M[2, 2] := S.Z;
end;

function Mat4ScaleUniform(S: Single): TMat4;
begin
  Result := Mat4Identity;
  Result.M[0, 0] := S;
  Result.M[1, 1] := S;
  Result.M[2, 2] := S;
end;

function Mat4RotationX(AngleDeg: Single): TMat4;
var
  C, S: Single;
begin
  C := Cos(AngleDeg * Pi / 180);
  S := Sin(AngleDeg * Pi / 180);
  Result := Mat4Identity;
  Result.M[1, 1] := C;
  Result.M[1, 2] := S;
  Result.M[2, 1] := -S;
  Result.M[2, 2] := C;
end;

function Mat4RotationY(AngleDeg: Single): TMat4;
var
  C, S: Single;
begin
  C := Cos(AngleDeg * Pi / 180);
  S := Sin(AngleDeg * Pi / 180);
  Result := Mat4Identity;
  Result.M[0, 0] := C;
  Result.M[0, 2] := -S;
  Result.M[2, 0] := S;
  Result.M[2, 2] := C;
end;

function Mat4RotationZ(AngleDeg: Single): TMat4;
var
  C, S: Single;
begin
  C := Cos(AngleDeg * Pi / 180);
  S := Sin(AngleDeg * Pi / 180);
  Result := Mat4Identity;
  Result.M[0, 0] := C;
  Result.M[0, 1] := S;
  Result.M[1, 0] := -S;
  Result.M[1, 1] := C;
end;

function Mat4RotationAxis(const Axis: TVec3; AngleDeg: Single): TMat4;
var
  A: TVec3;
  C, S, T: Single;
begin
  A := Vec3Normalize(Axis);
  C := Cos(AngleDeg * Pi / 180);
  S := Sin(AngleDeg * Pi / 180);
  T := 1 - C;
  Result := Mat4Identity;
  Result.M[0, 0] := T * A.X * A.X + C;
  Result.M[0, 1] := T * A.X * A.Y + S * A.Z;
  Result.M[0, 2] := T * A.X * A.Z - S * A.Y;

  Result.M[1, 0] := T * A.X * A.Y - S * A.Z;
  Result.M[1, 1] := T * A.Y * A.Y + C;
  Result.M[1, 2] := T * A.Y * A.Z + S * A.X;

  Result.M[2, 0] := T * A.X * A.Z + S * A.Y;
  Result.M[2, 1] := T * A.Y * A.Z - S * A.X;
  Result.M[2, 2] := T * A.Z * A.Z + C;
end;

function Mat4LookAt(const Eye, Target, Up: TVec3): TMat4;
var
  F, S, U: TVec3;
begin
  F := Vec3Normalize(Vec3Sub(Target, Eye));
  S := Vec3Cross(F, Up);
  if Vec3LengthSq(S) < 1E-12 then
    S := Vec3Cross(F, Vec3(0, 0, 1));
  S := Vec3Normalize(S);
  U := Vec3Cross(S, F);

  Result := Mat4Identity;
  Result.M[0, 0] := S.X;
  Result.M[0, 1] := S.Y;
  Result.M[0, 2] := S.Z;
  Result.M[1, 0] := U.X;
  Result.M[1, 1] := U.Y;
  Result.M[1, 2] := U.Z;
  Result.M[2, 0] := -F.X;
  Result.M[2, 1] := -F.Y;
  Result.M[2, 2] := -F.Z;
  Result.M[3, 0] := -Vec3Dot(S, Eye);
  Result.M[3, 1] := -Vec3Dot(U, Eye);
  Result.M[3, 2] := Vec3Dot(F, Eye);
end;

function Mat4Perspective(FovYDeg, Aspect, ZNear, ZFar: Single): TMat4;
var
  F, Range: Single;
begin
  F := 1 / Tan(FovYDeg * Pi / 360);
  Range := ZFar - ZNear;
  Result := Mat4Identity;
  Result.M[0, 0] := F / Aspect;
  Result.M[1, 1] := F;
  Result.M[2, 2] := (ZFar + ZNear) / (ZNear - ZFar);
  Result.M[2, 3] := -1;
  Result.M[3, 2] := -2 * ZFar * ZNear / Range;
  Result.M[3, 3] := 0;
end;

function Mat4Ortho(Left, Right, Bottom, Top, ZNear, ZFar: Single): TMat4;
begin
  Result := Mat4Identity;
  Result.M[0, 0] := 2 / (Right - Left);
  Result.M[1, 1] := 2 / (Top - Bottom);
  Result.M[2, 2] := -2 / (ZFar - ZNear);
  Result.M[3, 0] := -(Right + Left) / (Right - Left);
  Result.M[3, 1] := -(Top + Bottom) / (Top - Bottom);
  Result.M[3, 2] := -(ZFar + ZNear) / (ZFar - ZNear);
end;

function Mat4Column(const M: TMat4; Index: LongInt): TVec4;
begin
  Result.X := M[Index, 0];
  Result.Y := M[Index, 1];
  Result.Z := M[Index, 2];
  Result.W := M[Index, 3];
end;

function Mat4FromColumns(const C0, C1, C2, C3: TVec4): TMat4;
begin
  Result.M[0, 0] := C0.X; Result.M[0, 1] := C0.Y;
  Result.M[0, 2] := C0.Z; Result.M[0, 3] := C0.W;
  Result.M[1, 0] := C1.X; Result.M[1, 1] := C1.Y;
  Result.M[1, 2] := C1.Z; Result.M[1, 3] := C1.W;
  Result.M[2, 0] := C2.X; Result.M[2, 1] := C2.Y;
  Result.M[2, 2] := C2.Z; Result.M[2, 3] := C2.W;
  Result.M[3, 0] := C3.X; Result.M[3, 1] := C3.Y;
  Result.M[3, 2] := C3.Z; Result.M[3, 3] := C3.W;
end;

function Mat4Inverse(const M: TMat4): TMat4;
{ Gauss-Jordan with partial pivoting - slower than a cofactor expansion but
  short, and easy to trust. Singular matrices return the identity. }
var
  A: array[0..3, 0..7] of Double;
  I, J, K, P: LongInt;
  T, Best: Double;
begin
  for I := 0 to 3 do
    for J := 0 to 3 do
      begin
        A[I, J] := M[J, I];
        if I = J then A[I, J + 4] := 1 else A[I, J + 4] := 0;
      end;

  for I := 0 to 3 do
    begin
      P := I;
      Best := Abs(A[I, I]);
      for K := I + 1 to 3 do
        if Abs(A[K, I]) > Best then
          begin
            Best := Abs(A[K, I]);
            P := K;
          end;
      if Best < 1E-15 then
        begin
          Result := Mat4Identity;
          Exit;
        end;
      if P <> I then
        for J := 0 to 7 do
          begin
            T := A[I, J]; A[I, J] := A[P, J]; A[P, J] := T;
          end;
      T := A[I, I];
      for J := 0 to 7 do A[I, J] := A[I, J] / T;
      for K := 0 to 3 do
        if K <> I then
          begin
            T := A[K, I];
            if T <> 0 then
              for J := 0 to 7 do A[K, J] := A[K, J] - T * A[I, J];
          end;
    end;

  for I := 0 to 3 do
    for J := 0 to 3 do
      Result.M[J, I] := A[I, J + 4];
end;

function Mat4Transpose(const M: TMat4): TMat4;
var
  C, R: LongInt;
begin
  for C := 0 to 3 do
    for R := 0 to 3 do
      Result.M[C, R] := M.M[R, C];
end;

function Mat4NormalMatrix(const M: TMat4): TMat4;
{ inverse transpose of the upper 3x3 part, stored in a 4x4 with no translation }
begin
  Result := Mat4Transpose(Mat4Inverse(M));
  Result.M[3, 0] := 0;
  Result.M[3, 1] := 0;
  Result.M[3, 2] := 0;
  Result.M[3, 3] := 1;
  Result.M[0, 3] := 0;
  Result.M[1, 3] := 0;
  Result.M[2, 3] := 0;
end;

function Mat4Compose(const Pos, RotDeg, Scale: TVec3): TMat4;
begin
  Result := Mat4Translation(Pos) * Mat4RotationZ(RotDeg.Z) * Mat4RotationY(RotDeg.Y) *
            Mat4RotationX(RotDeg.X) * Mat4Scale(Scale);
end;

function Mat4MulPoint(const M: TMat4; const P: TVec3): TVec3;
begin
  Result.X := M.M[0, 0] * P.X + M.M[1, 0] * P.Y + M.M[2, 0] * P.Z + M.M[3, 0];
  Result.Y := M.M[0, 1] * P.X + M.M[1, 1] * P.Y + M.M[2, 1] * P.Z + M.M[3, 1];
  Result.Z := M.M[0, 2] * P.X + M.M[1, 2] * P.Y + M.M[2, 2] * P.Z + M.M[3, 2];
end;

function Mat4MulPoint4(const M: TMat4; const P: TVec3): TVec4;
begin
  Result.X := M.M[0, 0] * P.X + M.M[1, 0] * P.Y + M.M[2, 0] * P.Z + M.M[3, 0];
  Result.Y := M.M[0, 1] * P.X + M.M[1, 1] * P.Y + M.M[2, 1] * P.Z + M.M[3, 1];
  Result.Z := M.M[0, 2] * P.X + M.M[1, 2] * P.Y + M.M[2, 2] * P.Z + M.M[3, 2];
  Result.W := M.M[0, 3] * P.X + M.M[1, 3] * P.Y + M.M[2, 3] * P.Z + M.M[3, 3];
end;

function Mat4MulDir(const M: TMat4; const D: TVec3): TVec3;
begin
  Result.X := M.M[0, 0] * D.X + M.M[1, 0] * D.Y + M.M[2, 0] * D.Z;
  Result.Y := M.M[0, 1] * D.X + M.M[1, 1] * D.Y + M.M[2, 1] * D.Z;
  Result.Z := M.M[0, 2] * D.X + M.M[1, 2] * D.Y + M.M[2, 2] * D.Z;
end;

function Mat4GetTranslation(const M: TMat4): TVec3;
begin
  Result.X := M.M[3, 0];
  Result.Y := M.M[3, 1];
  Result.Z := M.M[3, 2];
end;

function Mat4Determinant3(const M: TMat4): Single;
begin
  Result :=
      M.M[0, 0] * (M.M[1, 1] * M.M[2, 2] - M.M[2, 1] * M.M[1, 2])
    - M.M[1, 0] * (M.M[0, 1] * M.M[2, 2] - M.M[2, 1] * M.M[0, 2])
    + M.M[2, 0] * (M.M[0, 1] * M.M[1, 2] - M.M[1, 1] * M.M[0, 2]);
end;

{ =================================================================== aabb == }

function AABBEmpty: TAABB;
begin
  Result.Min := Vec3(1E30, 1E30, 1E30);
  Result.Max := Vec3(-1E30, -1E30, -1E30);
  Result.Valid := False;
end;

function AABBFromPoints(const A, B: TVec3): TAABB;
begin
  Result.Min := Vec3Min(A, B);
  Result.Max := Vec3Max(A, B);
  Result.Valid := True;
end;

function AABBExpand(const A: TAABB; Point: TVec3): TAABB;
begin
  if not A.Valid then
    begin
      Result.Min := Point;
      Result.Max := Point;
      Result.Valid := True;
    end
  else
    begin
      Result.Min := Vec3Min(A.Min, Point);
      Result.Max := Vec3Max(A.Max, Point);
      Result.Valid := True;
    end;
end;

function AABBUnion(const A, B: TAABB): TAABB;
begin
  if not A.Valid then Exit(B);
  if not B.Valid then Exit(A);
  Result.Min := Vec3Min(A.Min, B.Min);
  Result.Max := Vec3Max(A.Max, B.Max);
  Result.Valid := True;
end;

function AABBCenter(const B: TAABB): TVec3;
begin
  Result := Vec3Scale(Vec3Add(B.Min, B.Max), 0.5);
end;

function AABBExtents(const B: TAABB): TVec3;
begin
  Result := Vec3Scale(Vec3Sub(B.Max, B.Min), 0.5);
end;

function AABBRadius(const B: TAABB): Single;
begin
  if not B.Valid then Exit(0);
  Result := Vec3Length(AABBExtents(B));
end;

function AABBTransform(const B: TAABB; const M: TMat4): TAABB;
var
  I: LongInt;
  P: TVec3;
begin
  Result := AABBEmpty;
  if not B.Valid then Exit;
  for I := 0 to 7 do
    begin
      if (I and 1) = 0 then P.X := B.Min.X else P.X := B.Max.X;
      if (I and 2) = 0 then P.Y := B.Min.Y else P.Y := B.Max.Y;
      if (I and 4) = 0 then P.Z := B.Min.Z else P.Z := B.Max.Z;
      Result := AABBExpand(Result, Mat4MulPoint(M, P));
    end;
end;

function AABBContainsPoint(const B: TAABB; const P: TVec3): Boolean;
begin
  Result := (P.X >= B.Min.X) and (P.X <= B.Max.X) and
            (P.Y >= B.Min.Y) and (P.Y <= B.Max.Y) and
            (P.Z >= B.Min.Z) and (P.Z <= B.Max.Z);
end;

{ ================================================================ frustum == }

function PlaneFromRows(const A, B: TVec4): TVec4;
begin
  Result.X := A.X + B.X;
  Result.Y := A.Y + B.Y;
  Result.Z := A.Z + B.Z;
  Result.W := A.W + B.W;
end;

function PlaneFromSub(const A, B: TVec4): TVec4;
begin
  Result.X := A.X - B.X;
  Result.Y := A.Y - B.Y;
  Result.Z := A.Z - B.Z;
  Result.W := A.W - B.W;
end;

function FrustumFromViewProj(const M: TMat4): TFrustum;
var
  R0, R1, R2, R3: TVec4;
  P: TVec4;
  I: LongInt;
  L: Single;
begin
  R0.X := M.M[0, 0]; R0.Y := M.M[1, 0]; R0.Z := M.M[2, 0]; R0.W := M.M[3, 0];
  R1.X := M.M[0, 1]; R1.Y := M.M[1, 1]; R1.Z := M.M[2, 1]; R1.W := M.M[3, 1];
  R2.X := M.M[0, 2]; R2.Y := M.M[1, 2]; R2.Z := M.M[2, 2]; R2.W := M.M[3, 2];
  R3.X := M.M[0, 3]; R3.Y := M.M[1, 3]; R3.Z := M.M[2, 3]; R3.W := M.M[3, 3];

  Result.Planes[0] := PlaneFromRows(R3, R0);   // left
  Result.Planes[1] := PlaneFromSub(R3, R0);    // right
  Result.Planes[2] := PlaneFromRows(R3, R1);   // bottom
  Result.Planes[3] := PlaneFromSub(R3, R1);    // top
  Result.Planes[4] := PlaneFromRows(R3, R2);   // near
  Result.Planes[5] := PlaneFromSub(R3, R2);    // far

  for I := 0 to 5 do
    begin
      P := Result.Planes[I];
      L := Sqrt(P.X * P.X + P.Y * P.Y + P.Z * P.Z);
      if L > 1E-20 then
        begin
          Result.Planes[I].X := P.X / L;
          Result.Planes[I].Y := P.Y / L;
          Result.Planes[I].Z := P.Z / L;
          Result.Planes[I].W := P.W / L;
        end;
    end;
end;

function FrustumTestPoint(const F: TFrustum; const P: TVec3): Boolean;
var
  I: LongInt;
  Pl: TVec4;
begin
  Result := True;
  for I := 0 to 5 do
    begin
      Pl := F.Planes[I];
      if Pl.X * P.X + Pl.Y * P.Y + Pl.Z * P.Z + Pl.W < 0 then
        Exit(False);
    end;
end;

function FrustumTestSphere(const F: TFrustum; const C: TVec3; Radius: Single): Boolean;
var
  I: LongInt;
  Pl: TVec4;
begin
  Result := True;
  for I := 0 to 5 do
    begin
      Pl := F.Planes[I];
      if Pl.X * C.X + Pl.Y * C.Y + Pl.Z * C.Z + Pl.W < -Radius then
        Exit(False);
    end;
end;

function FrustumTestAABB(const F: TFrustum; const B: TAABB): Boolean;
var
  I: LongInt;
  Pl: TVec4;
  P: TVec3;
begin
  Result := True;
  if not B.Valid then Exit(False);
  for I := 0 to 5 do
    begin
      Pl := F.Planes[I];
      // positive vertex: the corner furthest along the plane normal
      if Pl.X >= 0 then P.X := B.Max.X else P.X := B.Min.X;
      if Pl.Y >= 0 then P.Y := B.Max.Y else P.Y := B.Min.Y;
      if Pl.Z >= 0 then P.Z := B.Max.Z else P.Z := B.Min.Z;
      if Pl.X * P.X + Pl.Y * P.Y + Pl.Z * P.Z + Pl.W < 0 then
        Exit(False);
    end;
end;

{ ================================================================= random == }

function RandomNext(var State: QWord): QWord;
{ xorshift64*, fast and good enough for graphics }
begin
  State := State xor (State shr 12);
  State := State xor (State shl 25);
  State := State xor (State shr 27);
  Result := State * QWord(2685821657736338717);
end;

function RandomFloat(var State: QWord): Single;
begin
  Result := (RandomNext(State) shr 40) * (1.0 / 16777216.0);
end;

function RandomRange(var State: QWord; A, B: Single): Single;
begin
  Result := A + (B - A) * RandomFloat(State);
end;

function Hash3(Seed: LongWord; X, Y, Z: LongInt): LongWord;
var
  H: LongWord;
begin
  H := Seed;
  H := H xor LongWord(X) * 374761393;
  H := (H shl 13) or (H shr 19);
  H := H xor LongWord(Y) * 668265263;
  H := (H shl 17) or (H shr 15);
  H := H xor LongWord(Z) * 2147483647;
  H := H xor (H shr 16);
  Result := H;
end;

{ ================================================================== noise == }

function HashToUnit(H: LongWord): Single;
begin
  Result := (H and $FFFFFF) * (1.0 / 16777216.0);
end;

function Noise2D(X, Y: Single; Seed: LongWord): Single;
var
  IX, IY: LongInt;
  FX, FY: Single;
  V00, V10, V01, V11: Single;
  SX, SY: Single;
begin
  IX := Floor(X);
  IY := Floor(Y);
  FX := X - IX;
  FY := Y - IY;
  SX := FX * FX * (3 - 2 * FX);
  SY := FY * FY * (3 - 2 * FY);

  V00 := HashToUnit(Hash3(Seed, IX, IY, 0));
  V10 := HashToUnit(Hash3(Seed, IX + 1, IY, 0));
  V01 := HashToUnit(Hash3(Seed, IX, IY + 1, 0));
  V11 := HashToUnit(Hash3(Seed, IX + 1, IY + 1, 0));

  Result := LerpS(LerpS(V00, V10, SX), LerpS(V01, V11, SX), SY);
end;

function Noise3D(X, Y, Z: Single; Seed: LongWord): Single;
var
  IX, IY, IZ: LongInt;
  FX, FY, FZ: Single;
  SX, SY, SZ: Single;
  C000, C100, C010, C110, C001, C101, C011, C111: Single;
  X00, X10, X01, X11, Y0, Y1: Single;
begin
  IX := Floor(X);
  IY := Floor(Y);
  IZ := Floor(Z);
  FX := X - IX;
  FY := Y - IY;
  FZ := Z - IZ;
  SX := FX * FX * (3 - 2 * FX);
  SY := FY * FY * (3 - 2 * FY);
  SZ := FZ * FZ * (3 - 2 * FZ);

  C000 := HashToUnit(Hash3(Seed, IX, IY, IZ));
  C100 := HashToUnit(Hash3(Seed, IX + 1, IY, IZ));
  C010 := HashToUnit(Hash3(Seed, IX, IY + 1, IZ));
  C110 := HashToUnit(Hash3(Seed, IX + 1, IY + 1, IZ));
  C001 := HashToUnit(Hash3(Seed, IX, IY, IZ + 1));
  C101 := HashToUnit(Hash3(Seed, IX + 1, IY, IZ + 1));
  C011 := HashToUnit(Hash3(Seed, IX, IY + 1, IZ + 1));
  C111 := HashToUnit(Hash3(Seed, IX + 1, IY + 1, IZ + 1));

  X00 := LerpS(C000, C100, SX);
  X10 := LerpS(C010, C110, SX);
  X01 := LerpS(C001, C101, SX);
  X11 := LerpS(C011, C111, SX);
  Y0 := LerpS(X00, X10, SY);
  Y1 := LerpS(X01, X11, SY);
  Result := LerpS(Y0, Y1, SZ);
end;

function FBM2D(X, Y: Single; Octaves: LongInt; Seed: LongWord): Single;
var
  I: LongInt;
  Amp, Freq, Sum, Norm: Single;
begin
  Amp := 0.5;
  Freq := 1;
  Sum := 0;
  Norm := 0;
  for I := 0 to Octaves - 1 do
    begin
      Sum := Sum + Amp * Noise2D(X * Freq, Y * Freq, Seed + LongWord(I) * 1013);
      Norm := Norm + Amp;
      Amp := Amp * 0.5;
      Freq := Freq * 2;
    end;
  if Norm > 0 then Result := Sum / Norm else Result := 0;
end;

{ =============================================================== operators == }

operator + (const A, B: TVec2) R: TVec2;
begin
  R.X := A.X + B.X;
  R.Y := A.Y + B.Y;
end;

operator - (const A, B: TVec2) R: TVec2;
begin
  R.X := A.X - B.X;
  R.Y := A.Y - B.Y;
end;

operator * (const A: TVec2; S: Single) R: TVec2;
begin
  R.X := A.X * S;
  R.Y := A.Y * S;
end;

operator + (const A, B: TVec3) R: TVec3;
begin
  R.X := A.X + B.X;
  R.Y := A.Y + B.Y;
  R.Z := A.Z + B.Z;
end;

operator - (const A, B: TVec3) R: TVec3;
begin
  R.X := A.X - B.X;
  R.Y := A.Y - B.Y;
  R.Z := A.Z - B.Z;
end;

operator - (const A: TVec3) R: TVec3;
begin
  R.X := -A.X;
  R.Y := -A.Y;
  R.Z := -A.Z;
end;

operator * (const A: TVec3; S: Single) R: TVec3;
begin
  R.X := A.X * S;
  R.Y := A.Y * S;
  R.Z := A.Z * S;
end;

operator * (S: Single; const A: TVec3) R: TVec3;
begin
  R.X := A.X * S;
  R.Y := A.Y * S;
  R.Z := A.Z * S;
end;

operator / (const A: TVec3; S: Single) R: TVec3;
begin
  R.X := A.X / S;
  R.Y := A.Y / S;
  R.Z := A.Z / S;
end;

operator + (const A, B: TVec4) R: TVec4;
begin
  R.X := A.X + B.X;
  R.Y := A.Y + B.Y;
  R.Z := A.Z + B.Z;
  R.W := A.W + B.W;
end;

operator * (const A: TVec4; S: Single) R: TVec4;
begin
  R.X := A.X * S;
  R.Y := A.Y * S;
  R.Z := A.Z * S;
  R.W := A.W * S;
end;

operator * (const A, B: TMat4) R: TMat4;
var
  C, RW, K: LongInt;
begin
  for C := 0 to 3 do
    for RW := 0 to 3 do
      R.M[C, RW] := A.M[0, RW] * B.M[C, 0] + A.M[1, RW] * B.M[C, 1] +
                    A.M[2, RW] * B.M[C, 2] + A.M[3, RW] * B.M[C, 3];
end;

operator * (const A: TMat4; const V: TVec4) R: TVec4;
begin
  R.X := A.M[0, 0] * V.X + A.M[1, 0] * V.Y + A.M[2, 0] * V.Z + A.M[3, 0] * V.W;
  R.Y := A.M[0, 1] * V.X + A.M[1, 1] * V.Y + A.M[2, 1] * V.Z + A.M[3, 1] * V.W;
  R.Z := A.M[0, 2] * V.X + A.M[1, 2] * V.Y + A.M[2, 2] * V.Z + A.M[3, 2] * V.W;
  R.W := A.M[0, 3] * V.X + A.M[1, 3] * V.Y + A.M[2, 3] * V.Z + A.M[3, 3] * V.W;
end;

end.
