{ Unit tests for hdeh_math: vectors, matrices, bounding volumes, frustum. }
unit test_math;
{$mode objfpc}{$H+}

interface

implementation

uses
  SysUtils, Math, testutil, hdeh_math;

procedure TestVecBasics;
var
  A, B, C: TVec3;
begin
  A := Vec3(1, 2, 3);
  B := Vec3(4, -5, 6);
  C := A + B;
  ExpectNearVec3('add', Vec3(5, -3, 9), C, 1E-5);
  C := A - B;
  ExpectNearVec3('sub', Vec3(-3, 7, -3), C, 1E-5);
  C := A * 2;
  ExpectNearVec3('scale', Vec3(2, 4, 6), C, 1E-5);
  C := 2 * A;
  ExpectNearVec3('scale left', Vec3(2, 4, 6), C, 1E-5);
  C := -A;
  ExpectNearVec3('neg', Vec3(-1, -2, -3), C, 1E-5);
  ExpectNear('dot', 12, Vec3Dot(A, B), 1E-5);
  C := Vec3Cross(Vec3UnitX, Vec3UnitY);
  ExpectNearVec3('cross x*y = z', Vec3UnitZ, C, 1E-5);
  ExpectNear('length 3,4 -> 5', 5, Vec3Length(Vec3(3, 4, 0)), 1E-5);
  C := Vec3Normalize(Vec3(0, 3, 4));
  ExpectNear('normalize length', 1, Vec3Length(C), 1E-5);
  ExpectNearVec3('normalize dir', Vec3(0, 0.6, 0.8), C, 1E-5);
  ExpectNear('normalize zero is zero', 0, Vec3Length(Vec3Normalize(Vec3Zero)), 1E-6);
  C := Vec3Reflect(Vec3(1, -1, 0), Vec3(0, 1, 0));
  ExpectNearVec3('reflect', Vec3(1, 1, 0), C, 1E-5);
end;

procedure TestVec4AndOperators;
var
  V: TVec4;
  A, B: TMat4;
begin
  V := Vec4(1, 2, 3, 1);
  V := V * 2;
  ExpectNear('vec4 scale x', 2, V.X, 1E-5);
  ExpectNear('vec4 scale w', 2, V.W, 1E-5);
  A := Mat4Translation(Vec3(1, 2, 3));
  B := Mat4Translation(Vec3(10, 20, 30));
  // translation concatenation: (A*B)*p == A*(B*p)
  ExpectNearVec3('mat mul order', Mat4MulPoint(A, Mat4MulPoint(B, Vec3Zero)),
    Mat4MulPoint(A * B, Vec3Zero), 1E-5);
end;

procedure TestMat4Identity;
var
  M, R: TMat4;
begin
  M := Mat4Identity;
  R := M * M;
  ExpectNearMat4('identity * identity', M, R, 1E-6);
  ExpectNearVec3('identity point', Vec3(1, 2, 3), Mat4MulPoint(M, Vec3(1, 2, 3)), 1E-6);
end;

procedure TestMat4TranslationScale;
var
  M: TMat4;
begin
  M := Mat4Translation(Vec3(10, 0, -5));
  ExpectNearVec3('translate point', Vec3(11, 2, -2), Mat4MulPoint(M, Vec3(1, 2, 3)), 1E-5);
  ExpectNearVec3('translate dir untouched', Vec3UnitX, Mat4MulDir(M, Vec3UnitX), 1E-5);
  M := Mat4Scale(Vec3(2, 3, 4));
  ExpectNearVec3('scale point', Vec3(2, 6, 12), Mat4MulPoint(M, Vec3(1, 2, 3)), 1E-5);
end;

procedure TestMat4Rotations;
var
  R: TMat4;
begin
  R := Mat4RotationY(90);
  ExpectNearVec3('rotY 90: +X -> -Z', Vec3(0, 0, -1), Mat4MulDir(R, Vec3UnitX), 1E-5);
  ExpectNearVec3('rotY 90: +Z -> +X', Vec3(1, 0, 0), Mat4MulDir(R, Vec3UnitZ), 1E-5);
  ExpectNearVec3('rotY 90: +Y stays', Vec3UnitY, Mat4MulDir(R, Vec3UnitY), 1E-5);

  R := Mat4RotationX(90);
  ExpectNearVec3('rotX 90: +Y -> +Z', Vec3(0, 0, 1), Mat4MulDir(R, Vec3UnitY), 1E-5);

  R := Mat4RotationZ(90);
  ExpectNearVec3('rotZ 90: +X -> +Y', Vec3(0, 1, 0), Mat4MulDir(R, Vec3UnitX), 1E-5);

  R := Mat4RotationAxis(Vec3(0, 0, 1), 180);
  ExpectNearVec3('rotAxis z 180: +X -> -X', Vec3(-1, 0, 0), Mat4MulDir(R, Vec3UnitX), 1E-5);
  R := Mat4RotationAxis(Vec3(1, 1, 1), 120);
  ExpectNearVec3('rotAxis 111 120: cycles', Vec3UnitY, Mat4MulDir(R, Vec3UnitX), 1E-4);
end;

procedure TestMat4Inverse;
var
  M, Inv, P: TMat4;
  I, J: LongInt;
  Ok: Boolean;
begin
  M := Mat4Translation(Vec3(3, -2, 7)) * Mat4RotationY(33) * Mat4RotationX(17) *
       Mat4Scale(Vec3(2, 0.5, 1.5));
  Inv := Mat4Inverse(M);
  P := M * Inv;
  Ok := True;
  for I := 0 to 3 do
    for J := 0 to 3 do
      begin
        if I = J then
          begin
            if Abs(P.M[I, J] - 1) > 1E-4 then Ok := False;
          end
        else if Abs(P.M[I, J]) > 1E-4 then
          Ok := False;
      end;
  Expect(Ok, 'M * inverse(M) is identity');
  ExpectNearVec3('inverse undoes transform',
    Vec3(1, 2, 3), Mat4MulPoint(Inv, Mat4MulPoint(M, Vec3(1, 2, 3))), 1E-3);
  // singular matrix falls back to identity instead of producing NaNs
  P := Mat4Inverse(Mat4Scale(Vec3(1, 0, 1)));
  ExpectNearMat4('singular inverse', Mat4Identity, P, 1E-6);
end;

procedure TestMat4NormalMatrix;
var
  M, N: TMat4;
begin
  // non uniform scale: normal matrix must not simply reuse the model matrix
  M := Mat4Scale(Vec3(1, 4, 1));
  N := Mat4NormalMatrix(M);
  ExpectNearVec3('normal matrix scales inverse', Vec3(1, 0.25, 1),
    Mat4MulDir(N, Vec3(1, 1, 1)), 1E-5);
end;

procedure TestLookAt;
var
  View: TMat4;
begin
  View := Mat4LookAt(Vec3(0, 0, 5), Vec3(0, 0, 0), Vec3(0, 1, 0));
  ExpectNearVec3('origin 5 in front', Vec3(0, 0, -5), Mat4MulPoint(View, Vec3Zero), 1E-5);
  ExpectNearVec3('+X right', Vec3(1, 0, -5), Mat4MulPoint(View, Vec3UnitX), 1E-5);
  ExpectNearVec3('+Y up', Vec3(0, 1, -5), Mat4MulPoint(View, Vec3UnitY), 1E-5);

  View := Mat4LookAt(Vec3(5, 0, 0), Vec3(0, 0, 0), Vec3(0, 1, 0));
  ExpectNearVec3('camera on +X looks to -X', Vec3(0, 0, -5), Mat4MulPoint(View, Vec3Zero), 1E-4);
end;

procedure TestPerspective;
var
  P: TMat4;
  Cl: TVec4;
begin
  P := Mat4Perspective(90, 1, 1, 100);
  // half fov is 45 degrees -> at distance 1 the visible half height is 1
  ExpectNear('perspective [1][1]', 1, P.M[1, 1], 1E-5);
  ExpectNear('perspective w', -1, P.M[2, 3], 1E-5);

  Cl := P * Vec4(0, 0, -1, 1);
  ExpectNear('near plane ndc z', -1, Cl.Z / Cl.W, 1E-4);
  ExpectNear('near plane w', 1, Cl.W, 1E-5);
  Cl := P * Vec4(0, 0, -100, 1);
  ExpectNear('far plane ndc z', 1, Cl.Z / Cl.W, 1E-4);
  ExpectNear('far plane w', 100, Cl.W, 1E-4);
  // a point on the top edge of the frustum maps to ndc y = 1
  Cl := P * Vec4(0, 5, -5, 1);
  ExpectNear('top edge', 1, Cl.Y / Cl.W, 1E-4);
end;

procedure TestOrtho;
var
  O: TMat4;
  Cl: TVec4;
begin
  O := Mat4Ortho(-10, 10, -10, 10, 1, 101);
  Cl := O * Vec4(-10, 10, -1, 1);
  ExpectNear('ortho left/bottom', -1, Cl.X, 1E-5);
  ExpectNear('ortho top', 1, Cl.Y, 1E-5);
  ExpectNear('ortho near', -1, Cl.Z, 1E-5);
  Cl := O * Vec4(10, -10, -101, 1);
  ExpectNear('ortho right', 1, Cl.X, 1E-5);
  ExpectNear('ortho far', 1, Cl.Z, 1E-5);
end;

procedure TestAABB;
var
  B, T: TAABB;
  M: TMat4;
begin
  B := AABBFromPoints(Vec3(-1, -1, -1), Vec3(1, 1, 1));
  ExpectNearVec3('center', Vec3Zero, AABBCenter(B), 1E-6);
  ExpectNear('radius', Sqrt(3), AABBRadius(B), 1E-5);
  Expect(AABBContainsPoint(B, Vec3(0.5, 0.5, 0.5)), 'contains inner point');
  Expect(not AABBContainsPoint(B, Vec3(1.5, 0, 0)), 'does not contain outer point');

  M := Mat4Translation(Vec3(10, 0, 0)) * Mat4Scale(Vec3(2, 2, 2));
  T := AABBTransform(B, M);
  ExpectNearVec3('transformed min', Vec3(8, -2, -2), T.Min, 1E-5);
  ExpectNearVec3('transformed max', Vec3(12, 2, 2), T.Max, 1E-5);

  T := AABBUnion(B, AABBFromPoints(Vec3(5, 5, 5), Vec3(6, 6, 6)));
  ExpectNearVec3('union min', Vec3(-1, -1, -1), T.Min, 1E-5);
  ExpectNearVec3('union max', Vec3(6, 6, 6), T.Max, 1E-5);
end;

procedure TestFrustum;
var
  VP: TMat4;
  F: TFrustum;
  B: TAABB;
begin
  VP := Mat4Perspective(90, 1, 0.1, 100) * Mat4LookAt(Vec3(0, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0));
  F := FrustumFromViewProj(VP);
  Expect(FrustumTestPoint(F, Vec3(0, 0, -5)), 'point in front is visible');
  Expect(not FrustumTestPoint(F, Vec3(0, 0, 5)), 'point behind is culled');
  Expect(FrustumTestPoint(F, Vec3(4, 4, -5)), 'point at the edge is visible');
  Expect(not FrustumTestPoint(F, Vec3(40, 0, -5)), 'point far right is culled');
  Expect(FrustumTestSphere(F, Vec3(40, 0, -5), 36), 'sphere touching frustum is visible');
  Expect(not FrustumTestSphere(F, Vec3(0, 0, 200), 50), 'sphere behind is culled');

  B := AABBFromPoints(Vec3(-1, -1, -6), Vec3(1, 1, -4));
  Expect(FrustumTestAABB(F, B), 'box in front is visible');
  B := AABBFromPoints(Vec3(-1, -1, 4), Vec3(1, 1, 6));
  Expect(not FrustumTestAABB(F, B), 'box behind is culled');
end;

procedure TestNoiseAndRandom;
var
  S: QWord;
  V, R: Single;
  I: LongInt;
begin
  S := 12345;
  for I := 1 to 100 do
    begin
      V := RandomFloat(S);
      Expect((V >= 0) and (V < 1), 'random in range');
    end;
  S := 999;
  R := RandomRange(S, 5, 7);
  Expect((R >= 5) and (R <= 7), 'random range');

  V := Noise2D(3.5, 2.25, 7);
  Expect((V >= 0) and (V <= 1), 'noise in range');
  ExpectNear('noise is continuous', Noise2D(3.5, 2.25, 7), Noise2D(3.5001, 2.25, 7), 1E-3);
  ExpectNear('noise is integer periodic', Noise2D(3.0, 2.0, 7), Noise2D(4.0, 2.0, 7), 1E-4);
  V := FBM2D(1.25, 2.5, 4, 3);
  Expect((V >= 0) and (V <= 1), 'fbm in range');
end;

initialization
  RegisterTest('math.vec.basics', @TestVecBasics);
  RegisterTest('math.vec4.operators', @TestVec4AndOperators);
  RegisterTest('math.mat4.identity', @TestMat4Identity);
  RegisterTest('math.mat4.translation+scale', @TestMat4TranslationScale);
  RegisterTest('math.mat4.rotations', @TestMat4Rotations);
  RegisterTest('math.mat4.inverse', @TestMat4Inverse);
  RegisterTest('math.mat4.normalmatrix', @TestMat4NormalMatrix);
  RegisterTest('math.mat4.lookat', @TestLookAt);
  RegisterTest('math.mat4.perspective', @TestPerspective);
  RegisterTest('math.mat4.ortho', @TestOrtho);
  RegisterTest('math.aabb', @TestAABB);
  RegisterTest('math.frustum', @TestFrustum);
  RegisterTest('math.noise+random', @TestNoiseAndRandom);
end.
