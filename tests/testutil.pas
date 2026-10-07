{ Tiny self-contained test helper for the hdeh engine tests.  No external
  test framework is needed: tests register themselves, and a failing check
  raises ETestFailure, which the runner catches and reports. }
unit testutil;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, hdeh_math;

type
  TTestProc = procedure;
  ETestFailure = class(Exception);

procedure RegisterTest(const Name: string; Proc: TTestProc);
function RunAllTests: LongInt;

procedure Fail(const Msg: string);
procedure Expect(Cond: Boolean; const Msg: string);
procedure ExpectEqInt(const Msg: string; Expected, Actual: LongInt);
procedure ExpectNear(const Msg: string; Expected, Actual, Eps: Single);
procedure ExpectNearVec3(const Msg: string; const Expected, Actual: TVec3; Eps: Single);
procedure ExpectNearMat4(const Msg: string; const Expected, Actual: TMat4; Eps: Single);

implementation

const
  MaxTests = 1024;

var
  TestNames: array[0..MaxTests - 1] of string;
  TestProcs: array[0..MaxTests - 1] of TTestProc;
  TestCount: LongInt = 0;

procedure RegisterTest(const Name: string; Proc: TTestProc);
begin
  if TestCount >= MaxTests then
    raise Exception.Create('too many tests');
  TestNames[TestCount] := Name;
  TestProcs[TestCount] := Proc;
  Inc(TestCount);
end;

function RunAllTests: LongInt;
var
  I: LongInt;
  Failures: LongInt;
begin
  Failures := 0;
  WriteLn('== hdeh tests ==');
  for I := 0 to TestCount - 1 do
    begin
      try
        TestProcs[I]();
        WriteLn('[ ok ] ', TestNames[I]);
      except
        on E: ETestFailure do
          begin
            WriteLn('[FAIL] ', TestNames[I], ': ', E.Message);
            Inc(Failures);
          end;
        on E: Exception do
          begin
            WriteLn('[ERR ] ', TestNames[I], ': ', E.ClassName, ': ', E.Message);
            Inc(Failures);
          end;
      end;
    end;
  WriteLn(Format('---- %d tests, %d passed, %d failed ----',
    [TestCount, TestCount - Failures, Failures]));
  Result := Failures;
end;

procedure Fail(const Msg: string);
begin
  raise ETestFailure.Create(Msg);
end;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then
    Fail(Msg);
end;

procedure ExpectEqInt(const Msg: string; Expected, Actual: LongInt);
begin
  if Expected <> Actual then
    Fail(Format('%s: expected %d, got %d', [Msg, Expected, Actual]));
end;

procedure ExpectNear(const Msg: string; Expected, Actual, Eps: Single);
begin
  if Abs(Expected - Actual) > Eps then
    Fail(Format('%s: expected %.6f, got %.6f', [Msg, Expected, Actual]));
end;

procedure ExpectNearVec3(const Msg: string; const Expected, Actual: TVec3; Eps: Single);
begin
  if (Abs(Expected.X - Actual.X) > Eps) or (Abs(Expected.Y - Actual.Y) > Eps) or
     (Abs(Expected.Z - Actual.Z) > Eps) then
    Fail(Format('%s: expected (%.6f %.6f %.6f), got (%.6f %.6f %.6f)',
      [Msg, Expected.X, Expected.Y, Expected.Z, Actual.X, Actual.Y, Actual.Z]));
end;

procedure ExpectNearMat4(const Msg: string; const Expected, Actual: TMat4; Eps: Single);
var
  C, R: LongInt;
begin
  for C := 0 to 3 do
    for R := 0 to 3 do
      if Abs(Expected.M[C, R] - Actual.M[C, R]) > Eps then
        Fail(Format('%s: element [%d,%d]: expected %.6f, got %.6f',
          [Msg, C, R, Expected.M[C, R], Actual.M[C, R]]));
end;

end.
