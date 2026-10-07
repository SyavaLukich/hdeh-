{ hdeh test suite - runs every registered test and returns the number of
  failures as exit status. }
program hdeh_tests;
{$mode objfpc}{$H+}

uses
  SysUtils, testutil, test_math;

var
  Failures: LongInt;
begin
  Failures := RunAllTests;
  if Failures > 0 then
    Halt(1);
end.
