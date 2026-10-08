{ ============================================================================
  render_gl.pas  --  прогон НАСТОЯЩЕГО пути OpenGL без экрана и видеокарты

  В отличие от render_preview, здесь ничего не эмулируется. Контекст
  OpenGL 3.3 core создаётся через EGL на платформе surfaceless, драйвером
  служит программный растеризатор Mesa (softpipe). Дальше работает ровно тот
  код, что и в демо:

    * ugl      -- загрузка указателей на функции GL;
    * urender  -- компиляция ТЕХ САМЫХ шейдеров драйвером, uniform-переменные;
    * umesh    -- VAO, VBO, буфер экземпляров, glDrawElementsInstanced;
    * uscene   -- та же сцена и та же физика, что у программного превью.

  Рисуем в framebuffer-объект, читаем пиксели через glReadPixels и
  сохраняем кадр. Это и есть проверка настоящего графического конвейера.

      make render-gl     ->  build/gl.png
  ============================================================================ }
program render_gl;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugl, ugeom, ucamera, umesh, urender, ugjk, uphysics,
  uscene, uegl;

const
  W = 1280;
  H = 720;
  MAX_INST = 4096;

var
  g_cam: TCamera;
  g_mesh_box, g_mesh_ball, g_mesh_floor: TMesh;
  g_inst_box, g_inst_ball: array[0..MAX_INST - 1] of TInstance;
  g_inst_floor: array[0..7] of TInstance;
  fbo, rb_color, rb_depth: GLuint;

procedure save_bmp(const path: string; const px: array of Byte);
var
  f: file;
  hdr: array[0..53] of Byte;
  row: array of Byte;
  x, y, src: Integer;
  rowsize, datasize: LongWord;
begin
  rowsize := ((W * 3 + 3) div 4) * 4;
  datasize := rowsize * H;
  FillChar(hdr, SizeOf(hdr), 0);
  hdr[0] := Ord('B'); hdr[1] := Ord('M');
  PLongWord(@hdr[2])^ := 54 + datasize;
  PLongWord(@hdr[10])^ := 54;
  PLongWord(@hdr[14])^ := 40;
  PLongInt(@hdr[18])^ := W;
  PLongInt(@hdr[22])^ := H;
  PWord(@hdr[26])^ := 1;
  PWord(@hdr[28])^ := 24;
  PLongWord(@hdr[34])^ := datasize;

  SetLength(row, rowsize);
  AssignFile(f, path);
  Rewrite(f, 1);
  BlockWrite(f, hdr, 54);
  { glReadPixels отдаёт строки снизу вверх -- в BMP порядок такой же }
  for y := 0 to H - 1 do
  begin
    FillChar(row[0], rowsize, 0);
    for x := 0 to W - 1 do
    begin
      src := (y * W + x) * 4;
      row[x * 3 + 0] := px[src + 2];   { B }
      row[x * 3 + 1] := px[src + 1];   { G }
      row[x * 3 + 2] := px[src + 0];   { R }
    end;
    BlockWrite(f, row[0], rowsize);
  end;
  CloseFile(f);
end;

function make_fbo: Boolean;
var status: GLenum;
begin
  glGenFramebuffers(1, @fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);

  glGenRenderbuffers(1, @rb_color);
  glBindRenderbuffer(GL_RENDERBUFFER, rb_color);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, W, H);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_RENDERBUFFER, rb_color);

  glGenRenderbuffers(1, @rb_depth);
  glBindRenderbuffer(GL_RENDERBUFFER, rb_depth);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, W, H);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                            GL_RENDERBUFFER, rb_depth);

  status := glCheckFramebufferStatus(GL_FRAMEBUFFER);
  Result := status = GL_FRAMEBUFFER_COMPLETE;
  if not Result then
    WriteLn(Format('framebuffer не готов, код $%x', [status]));
end;

var
  msg: string;
  i, nb, ns, nf, culled: Integer;
  m: TMat4;
  box: TAABB;
  pixels: array of Byte;
  t0: TDateTime;
begin
  { Та же причина, что и в демо: маскируем исключения сопроцессора,
    иначе падаем внутри драйвера. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);

  { ---- 1. контекст ---- }
  if not egl_headless_init(msg) then
  begin
    WriteLn('EGL: ', msg);
    Halt(1);
  end;
  WriteLn('EGL: ', msg);

  { ---- 2. загрузка функций GL через eglGetProcAddress ---- }
  if not gl_load_with(@eglGetProcAddress) then
  begin
    WriteLn('не удалось загрузить функции OpenGL');
    Halt(1);
  end;
  WriteLn('GL_VERSION  : ', glGetString(GL_VERSION));
  WriteLn('GL_RENDERER : ', glGetString(GL_RENDERER));
  WriteLn('GL_VENDOR   : ', glGetString(GL_VENDOR));
  WriteLn('GLSL        : ', glGetString(GL_SHADING_LANGUAGE_VERSION));

  if not make_fbo then Halt(1);
  glViewport(0, 0, W, H);

  { ---- 3. инициализация рендерера: шейдеры компилирует сам драйвер ---- }
  if not render_init then
  begin
    WriteLn('render_init не удался');
    Halt(1);
  end;
  WriteLn('шейдеры скомпилированы драйвером: lit=', g_prog_lit.id,
          ' line=', g_prog_line.id);
  WriteLn('локации uniform: uViewProj=', g_prog_lit.uViewProj,
          ' uLightDir=', g_prog_lit.uLightDir,
          ' uCamPos=', g_prog_lit.uCamPos,
          ' uFogParams=', g_prog_lit.uFogParams);

  { ---- 4. геометрия в видеопамять ---- }
  g_mesh_box := mesh_make_box(v3(1, 1, 1));
  mesh_enable_instancing(g_mesh_box, MAX_INST);
  g_mesh_ball := mesh_make_sphere(1.0, 24, 16);
  mesh_enable_instancing(g_mesh_ball, MAX_INST);
  g_mesh_floor := mesh_make_box(v3(1, 1, 1));
  mesh_enable_instancing(g_mesh_floor, 8);
  if not gl_check('загрузка мешей') then Halt(1);

  { ---- 5. та же сцена и та же физика ---- }
  build_scene;
  scene_settle(300);
  WriteLn(Format('физика: %d тел, не спят: %d', [g_nbodies, g_stat_awake]));

  camera_init(g_cam, v3(13, 9, 21));
  g_cam.yaw := -2.25;
  g_cam.pitch := -0.33;
  camera_update(g_cam, W, H);

  { ---- 6. кадр ---- }
  t0 := Now;
  render_begin(g_cam);

  nb := 0; ns := 0; nf := 0; culled := 0;
  for i := 0 to g_nbodies - 1 do
  begin
    box := aabb_expand(g_bodies[i].box, 0.5);
    if not frustum_test_aabb(g_cam.frustum, box) then
    begin
      Inc(culled);
      Continue;
    end;
    m := m4_compose(g_bodies[i].pos, g_bodies[i].orient, g_scale[i]);
    case g_kind[i] of
      SC_BOX:
        if nb < MAX_INST then
        begin
          g_inst_box[nb].model := m;
          g_inst_box[nb].color := g_col[i];
          Inc(nb);
        end;
      SC_BALL:
        if ns < MAX_INST then
        begin
          g_inst_ball[ns].model := m;
          g_inst_ball[ns].color := g_col[i];
          Inc(ns);
        end;
      SC_FLOOR:
        if nf < 8 then
        begin
          g_inst_floor[nf].model := m;
          g_inst_floor[nf].color := g_col[i];
          Inc(nf);
        end;
    end;
  end;

  render_lit_begin(g_cam);
  render_draw_batch(g_mesh_floor, g_inst_floor, nf);
  render_draw_batch(g_mesh_box, g_inst_box, nb);
  render_draw_batch(g_mesh_ball, g_inst_ball, ns);
  glFinish;

  WriteLn(Format('нарисовано: пол %d, ящиков %d, шаров %d, отсечено %d, %.0f мс',
          [nf, nb, ns, culled, (Now - t0) * 24 * 60 * 60 * 1000]));
  if not gl_check('отрисовка кадра') then Halt(1);

  { ---- 7. читаем кадр обратно ---- }
  SetLength(pixels, W * H * 4);
  glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, @pixels[0]);
  if not gl_check('glReadPixels') then Halt(1);

  save_bmp('build/gl.bmp', pixels);
  WriteLn('сохранено: build/gl.bmp');

  render_shutdown;
  egl_headless_done;
end.
