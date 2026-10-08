{ ============================================================================
  render_preview.pas  --  предпросмотр кадра без видеокарты

  Строит ту же сцену, что и демо, гоняет физику и рисует кадр модулем
  usoftgl. Границы доверия к картинке честно перечислены в заголовке
  usoftgl.pas: это независимая реализация конвейера по спецификации GL,
  а не эталон и не доказательство корректности драйверного пути.

      make preview        ->  build/preview.png
  ============================================================================ }
program render_preview;

{$MODE OBJFPC}
{$H+}

uses
  SysUtils, Math, umath, ugeom, ucamera, ugjk, uphysics, uscene, usoftgl;

const
  W = 1280;
  H = 720;

var
  { геометрия }
  vb_box, vb_ball, vb_floor: TVertexArray;
  ib_box, ib_ball, ib_floor: TIndexArray;

{ =========================================================================
  Главная программа
  ========================================================================= }

var
  i, steps, culled: Integer;
  m: TMat4;
  t0: TDateTime;
  box: TAABB;
begin
  geom_box(v3(1, 1, 1), vb_box, ib_box);
  geom_sphere(1.0, 24, 16, vb_ball, ib_ball);
  geom_box(v3(1, 1, 1), vb_floor, ib_floor);

  WriteLn(Format('геометрия: ящик %d верш./%d инд., шар %d/%d',
          [Length(vb_box), Length(ib_box), Length(vb_ball), Length(ib_ball)]));

  build_scene;
  steps := 300;                      { 2.5 секунды физики }
  scene_settle(steps);
  WriteLn(Format('физика: %d тел, %d шагов, не спят: %d',
          [g_nbodies, steps, g_stat_awake]));

  camera_init(sg_cam, v3(13, 9, 21));
  sg_cam.yaw := -2.25;
  sg_cam.pitch := -0.33;
  camera_update(sg_cam, W, H);

  sg_init(W, H, sg_fog_color);

  t0 := Now;
  culled := 0;
  for i := 0 to g_nbodies - 1 do
  begin
    box := aabb_expand(g_bodies[i].box, 0.5);
    if not frustum_test_aabb(sg_cam.frustum, box) then
    begin
      Inc(culled);
      Continue;
    end;
    m := m4_compose(g_bodies[i].pos, g_bodies[i].orient, g_scale[i]);
    case g_kind[i] of
      SC_BOX: sg_draw(vb_box, ib_box, m, g_col[i]);
      SC_BALL: sg_draw(vb_ball, ib_ball, m, g_col[i]);
      SC_FLOOR: sg_draw(vb_floor, ib_floor, m, g_col[i]);
    end;
  end;

  WriteLn(Format('кадр: %dx%d, отсечено: %d тел, треугольников: %d, закрашено: %d, пикселей: %d, %.0f мс',
          [W, H, culled, sg_tris, sg_rastered, sg_pixels,
           (Now - t0) * 24 * 60 * 60 * 1000]));

  sg_save_bmp('build/preview.bmp');
  WriteLn('сохранено: build/preview.bmp');
end.
