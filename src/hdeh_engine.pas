{ ============================================================================
  hdeh-engine - the frame loop, the camera controller and the glue between
  scene, rasterizer, shadow maps and display back end.

  Typical use:

      Engine := TEngine.Create(Display, Scene, Camera);
      if Engine.Init then
        Engine.Run;

  An application subclasses TEngine and overrides the hooks it needs:

      procedure OnStart;                       - once, before the loop
      procedure OnUpdate(Dt: Single);           - advance the world
      procedure OnDraw;                         - overlay / extra passes
      procedure OnEvent(const E: TInputEvent);  - keyboard / mouse

  The default camera controller maps the usual WASD + arrow keys onto an
  orbit camera and, when switched to fly mode, onto a free camera.
  ============================================================================ }
unit hdeh_engine;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, hdeh_math, hdeh_image, hdeh_mesh, hdeh_scene,
  hdeh_raster, hdeh_shadow, hdeh_display;

type
  TCameraMode = (cmOrbit, cmFly);

  TCameraController = class
  public
    Mode: TCameraMode;
    Yaw, Pitch: Single;          // degrees
    Distance: Single;            // orbit radius
    Target: TVec3;               // orbit target / fly position reference
    Position: TVec3;             // free camera position in fly mode
    MoveSpeed: Single;           // units per second
    LookSpeed: Single;           // degrees per second (keyboard look)
    MouseSensitivity: Single;    // degrees per pixel
    AutoYaw: Single;             // automatic rotation, degrees per second
    MinDistance, MaxDistance: Single;
    constructor Create;
    procedure Reset(Cam: TCamera);
    procedure SetMode(NewMode: TCameraMode; Cam: TCamera);
    procedure Update(Cam: TCamera; Input: TInputState; Dt: Single);
  end;

  TEngine = class
  private
    FRenderer: TRenderer;
    FScene: TScene;
    FCamera: TCamera;
    FDisplay: TDisplay;
    FInput: TInputState;
    FController: TCameraController;
    FRunning: Boolean;
    FFrame: LongInt;
    FTime: Single;
    FFPS: Single;
    FTargetFPS: Single;
    FStopAfterFrames: LongInt;
    FLastFrameStart: Double;
    FShadowsEnabled: Boolean;
    FShadowBox: TAABB;
    FShowTitle: Boolean;
  protected
    procedure PollInput;
    procedure UpdateStats(Dt: Single);
  public
    constructor Create(Display: TDisplay; Scene: TScene; Camera: TCamera);
    destructor Destroy; override;

    function Init: Boolean;
    procedure Run;
    procedure StepFrame(Dt: Single);
    procedure Stop;

    { hooks for applications }
    procedure OnStart; virtual;
    procedure OnUpdate(Dt: Single); virtual;
    procedure OnDraw; virtual;
    procedure OnEvent(const E: TInputEvent); virtual;

    property Renderer: TRenderer read FRenderer;
    property Scene: TScene read FScene;
    property Camera: TCamera read FCamera;
    property Display: TDisplay read FDisplay;
    property Input: TInputState read FInput;
    property Controller: TCameraController read FController;
    property Frame: LongInt read FFrame;
    property Time: Single read FTime;
    property FPS: Single read FFPS;
    property TargetFPS: Single read FTargetFPS write FTargetFPS;
    property StopAfterFrames: LongInt read FStopAfterFrames write FStopAfterFrames;
    property ShadowsEnabled: Boolean read FShadowsEnabled write FShadowsEnabled;
    property ShadowBox: TAABB read FShadowBox write FShadowBox;
    property ShowTitle: Boolean read FShowTitle write FShowTitle;
  end;

implementation

{ ========================================================= camera control == }

constructor TCameraController.Create;
begin
  inherited Create;
  Mode := cmOrbit;
  Yaw := 25;
  Pitch := 18;
  Distance := 14;
  Target := Vec3(0, 1, 0);
  Position := Vec3(0, 3, 12);
  MoveSpeed := 8;
  LookSpeed := 90;
  MouseSensitivity := 0.25;
  AutoYaw := 0;
  MinDistance := 1;
  MaxDistance := 200;
end;

procedure TCameraController.Reset(Cam: TCamera);
begin
  Target := Vec3(0, 1, 0);
  Distance := Vec3Distance(Cam.Position, Target);
  if Distance < MinDistance then Distance := MinDistance;
end;

procedure TCameraController.SetMode(NewMode: TCameraMode; Cam: TCamera);
begin
  if NewMode = Mode then Exit;
  if NewMode = cmFly then
    Position := Cam.Position
  else
    begin
      // keep looking at what the free camera was looking at
      Target := Vec3Add(Cam.Position, Vec3Scale(Cam.Forward, Distance));
    end;
  Mode := NewMode;
end;

function DirectionFromAngles(YawDeg, PitchDeg: Single): TVec3;
var
  Y, P: Single;
begin
  Y := YawDeg * Pi / 180;
  P := PitchDeg * Pi / 180;
  Result := Vec3(Sin(Y) * Cos(P), Sin(P), -Cos(Y) * Cos(P));
end;

procedure TCameraController.Update(Cam: TCamera; Input: TInputState; Dt: Single);
var
  Turn, Step, Move: Single;
  Fwd, Right, Up, Delta, Dir: TVec3;
begin
  Turn := LookSpeed * Dt;
  Move := MoveSpeed * Dt;

  // mouse look (SDL only - the terminal has no mouse)
  Yaw := Yaw - Input.TakeMouseDeltaX * MouseSensitivity;
  Pitch := ClampS(Pitch - Input.TakeMouseDeltaY * MouseSensitivity, -89, 89);

  // keyboard look
  if Input.KeyDown(kLeft) then Yaw := Yaw + Turn;
  if Input.KeyDown(kRight) then Yaw := Yaw - Turn;
  if Input.KeyDown(kUp) then Pitch := ClampS(Pitch + Turn, -89, 89);
  if Input.KeyDown(kDown) then Pitch := ClampS(Pitch - Turn, -89, 89);

  if AutoYaw <> 0 then
    Yaw := Yaw + AutoYaw * Dt;

  Fwd := DirectionFromAngles(Yaw, Pitch);
  Right := Vec3Cross(Fwd, Vec3UnitY);
  if Vec3LengthSq(Right) < 1E-6 then Right := Vec3UnitX;
  Right := Vec3Normalize(Right);
  Up := Vec3UnitY;

  Step := 0;
  if Input.CharDown('w') or Input.CharDown('W') then Step := Step + 1;
  if Input.CharDown('s') or Input.CharDown('S') then Step := Step - 1;

  Delta := Vec3Zero;
  if Mode = cmOrbit then
    begin
      if Step <> 0 then
        Distance := ClampS(Distance * (1 - Step * 1.5 * Dt), MinDistance, MaxDistance);
      if Input.CharDown('a') or Input.CharDown('A') then Yaw := Yaw + Turn;
      if Input.CharDown('d') or Input.CharDown('D') then Yaw := Yaw - Turn;
      if Input.KeyDown(kPlus) or Input.CharDown('+') or Input.CharDown('=') then
        Distance := ClampS(Distance * (1 - 1.2 * Dt), MinDistance, MaxDistance);
      if Input.KeyDown(kMinus) or Input.CharDown('-') or Input.CharDown('_') then
        Distance := ClampS(Distance * (1 + 1.2 * Dt), MinDistance, MaxDistance);
      Cam.Position := Vec3Add(Target, Vec3Scale(DirectionFromAngles(Yaw, Pitch), Distance));
      Cam.Target := Target;
    end
  else
    begin
      if Step <> 0 then Delta := Delta + Vec3Scale(Fwd, Move * Step);
      if Input.CharDown('a') or Input.CharDown('A') then Delta := Delta - Vec3Scale(Right, Move);
      if Input.CharDown('d') or Input.CharDown('D') then Delta := Delta + Vec3Scale(Right, Move);
      if Input.CharDown('q') or Input.CharDown('Q') then Delta := Delta - Vec3Scale(Up, Move);
      if Input.CharDown('e') or Input.CharDown('E') then Delta := Delta + Vec3Scale(Up, Move);
      Position := Position + Delta;
      if Position.Y < 0.2 then Position.Y := 0.2;
      Cam.Position := Position;
      Dir := DirectionFromAngles(Yaw, Pitch);
      Cam.Target := Vec3Add(Position, Dir);
    end;
  Cam.Up := Vec3UnitY;
end;

{ ================================================================ engine === }

constructor TEngine.Create(Display: TDisplay; Scene: TScene; Camera: TCamera);
begin
  inherited Create;
  FDisplay := Display;
  FScene := Scene;
  FCamera := Camera;
  FInput := TInputState.Create;
  FController := TCameraController.Create;
  FRenderer := TRenderer.Create(80, 50);
  FRunning := False;
  FFrame := 0;
  FTime := 0;
  FFPS := 0;
  FTargetFPS := 60;
  FStopAfterFrames := 0;
  FShadowsEnabled := True;
  FShadowBox := AABBEmpty;
  FShowTitle := True;
end;

destructor TEngine.Destroy;
begin
  FreeAndNil(FRenderer);
  FreeAndNil(FController);
  FreeAndNil(FInput);
  inherited Destroy;
end;

function TEngine.Init: Boolean;
begin
  Result := False;
  if not FDisplay.Init then Exit;
  FRenderer.Resize(FDisplay.Width, FDisplay.Height);
  FController.Reset(FCamera);
  FLastFrameStart := NowSeconds;
  Result := True;
end;

procedure TEngine.PollInput;
var
  E: TInputEvent;
  Now: Double;
begin
  Now := NowSeconds;
  while FDisplay.PollEvent(E) do
    begin
      case E.Kind of
        ieQuit:
          Stop;
        ieResize:
          begin
            FRenderer.Resize(E.Width, E.Height);
            if FRenderer.Width < 1 then Stop;
          end;
      end;
      FInput.HandleEvent(E, Now);
      OnEvent(E);
    end;
  FInput.Expire(Now);
  if FInput.QuitRequested then Stop;
end;

procedure TEngine.UpdateStats(Dt: Single);
begin
  if Dt > 1E-5 then
    FFPS := FFPS * 0.9 + (1 / Dt) * 0.1
  else
    FFPS := FFPS;
end;

procedure TEngine.StepFrame(Dt: Single);
begin
  if Dt > 0 then
    begin
      FTime := FTime + Dt;
      UpdateStats(Dt);
    end;
  Inc(FFrame);

  OnUpdate(Dt);
  FController.Update(FCamera, FInput, Dt);
  FScene.UpdateTransforms;

  FRenderer.BeginFrame(FScene, FCamera);
  if FShadowsEnabled and FRenderer.Settings.Shadows then
    ShadowPasses(FRenderer, FScene, FShadowBox);
  FRenderer.DrawScene(FScene);
  OnDraw;
  FDisplay.Present(FRenderer);
  FInput.EndFrame;

  if FShowTitle and (FFrame mod 15 = 0) then
    FDisplay.SetTitle(Format('hdeh 3D - %.1f fps - %d triangles - %dx%d',
      [FFPS, FRenderer.Stats.TrianglesDrawn, FRenderer.Width, FRenderer.Height]));
end;

procedure TEngine.Run;
var
  FrameStart, Elapsed, Wait: Double;
  Dt: Single;
begin
  if not Init then Exit;
  FRunning := True;
  OnStart;
  FLastFrameStart := NowSeconds;
  while FRunning do
    begin
      FrameStart := NowSeconds;
      PollInput;
      if not FRunning then Break;

      Dt := FrameStart - FLastFrameStart;
      FLastFrameStart := FrameStart;
      if Dt > 0.25 then Dt := 0.25;      // avoid a huge jump after a break
      if Dt < 0 then Dt := 0;

      StepFrame(Dt);

      if (FStopAfterFrames > 0) and (FFrame >= FStopAfterFrames) then
        Stop;

      if (FTargetFPS > 0) and FRunning then
        begin
          Elapsed := NowSeconds - FrameStart;
          Wait := 1 / FTargetFPS - Elapsed;
          if Wait > 0.001 then
            Sleep(Round(Wait * 1000));
        end;
    end;
  FDisplay.Shutdown;
end;

procedure TEngine.Stop;
begin
  FRunning := False;
end;

procedure TEngine.OnStart;
begin
end;

procedure TEngine.OnUpdate(Dt: Single);
begin
end;

procedure TEngine.OnDraw;
begin
end;

procedure TEngine.OnEvent(const E: TInputEvent);
begin
end;

end.
