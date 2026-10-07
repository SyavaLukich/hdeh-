# ============================================================
#  Сборка 3D-движка на Free Pascal
#  Требуется: fpc >= 3.2 и GLFW 3.3 вместе с пакетом разработчика
#  (Debian/Ubuntu: fpc libglfw3-dev, macOS: brew install fpc glfw)
#
#  Свой компилятор можно подсунуть так:
#      make FPC=/путь/к/ppcx64 RTL=/путь/к/units/x86_64-linux
# ============================================================

FPC      ?= fpc
OUT      ?= build
BIN      := $(OUT)/engine3d
TESTBIN  := $(OUT)/test_physics
RTESTBIN := $(OUT)/test_render
XTESTBIN := $(OUT)/test_raster
PREVBIN  := $(OUT)/render_preview
SRC      := src/main.pas

# Если указан RTL -- добавляем пути к модулям RTL вручную
# (нужно, когда компилятор запускается не из установленного окружения).
ifneq ($(RTL),)
RTLFLAGS := -Fu$(RTL)/rtl -Fu$(RTL)/rtl-objpas -Fu$(RTL)/rtl-extra -Fu$(RTL)/rtl-console
endif

# -O3         агрессивная оптимизация
# -OoFASTMATH разрешить переупорядочивание вещественной арифметики
# -CpCOREAVX2 целевой набор инструкций современного процессора
# -Xs         убрать символы из бинарника
# -XX -CX     умная компоновка: выкидывает неиспользуемый код
COMMON   := $(RTLFLAGS) -Fusrc -FU$(OUT)/units -FE$(OUT)
FLAGS    := -O3 -OoFASTMATH -CpCOREAVX2 -Xs -XX -CX $(COMMON)
PORTFLAGS:= -O3 -Xs -XX -CX $(COMMON)
DBGFLAGS := -O1 -g -gl -Criot $(COMMON)

all: dirs
	$(FPC) $(FLAGS) -oengine3d $(SRC)

# Сборка без AVX2 -- для старых процессоров и виртуальных машин
portable: dirs
	$(FPC) $(PORTFLAGS) -oengine3d $(SRC)

debug: dirs
	$(FPC) $(DBGFLAGS) -oengine3d $(SRC)

# Тесты. Ни OpenGL, ни GLFW, ни дисплей для них не нужны.
test: test-physics test-render test-raster test-anim

test-physics: dirs
	$(FPC) -O3 $(RTLFLAGS) -Fusrc -FU$(OUT)/tunits -FE$(OUT) -otest_physics tests/test_physics.pas
	./$(TESTBIN)

test-render: dirs
	$(FPC) -O3 $(RTLFLAGS) -Fusrc -FU$(OUT)/tunits -FE$(OUT) -otest_render tests/test_render.pas
	./$(RTESTBIN)

# Скелет, анимация, суставы, рэгдол и слой поведения.
test-anim: dirs
	$(FPC) -O2 $(RTLFLAGS) -Fusrc -Futests -FU$(OUT)/tunits -FE$(OUT) -otest_anim tests/test_anim.pas
	./$(OUT)/test_anim

# Кадр со скелетной анимацией, рэгдолом и реакциями (программный растеризатор).
render-ragdoll: dirs
	$(FPC) -O2 $(RTLFLAGS) -Fusrc -Futests -FU$(OUT)/tunits -FE$(OUT) -orender_ragdoll tests/render_ragdoll.pas
	./$(OUT)/render_ragdoll
	@python3 tools/bmp2png.py $(OUT)/ragdoll.bmp $(OUT)/ragdoll.png 2>/dev/null \
	  && echo "также сохранено: $(OUT)/ragdoll.png" || true

# То же самое, но настоящим OpenGL через EGL (см. docs/headless-gl.md).
render-ragdoll-gl: dirs
	$(FPC) -O2 $(RTLFLAGS) $(if $(MESA),-Fl$(MESA)/lib/x86_64-linux-gnu) \
	  $(if $(GLFWLIB),-Fl$(GLFWLIB)) \
	  -Fusrc -Futests -FU$(OUT)/tunits -FE$(OUT) -orender_ragdoll_gl tests/render_ragdoll_gl.pas
	$(if $(MESA),LD_LIBRARY_PATH=$(MESA)/lib/x86_64-linux-gnu:$(GLFWLIB)) \
	  EGL_PLATFORM=surfaceless ./$(OUT)/render_ragdoll_gl
	@python3 tools/bmp2png.py $(OUT)/ragdoll_gl.bmp $(OUT)/ragdoll_gl.png 2>/dev/null \
	  && echo "также сохранено: $(OUT)/ragdoll_gl.png" || true

# Проверка самого программного растеризатора против спецификации OpenGL.
test-raster: dirs
	$(FPC) -O3 $(RTLFLAGS) -Fusrc -Futests -FU$(OUT)/tunits -FE$(OUT) -otest_raster tests/test_raster.pas
	./$(XTESTBIN)

# Кадр через отложенный конвейер ufox (настоящий OpenGL, см. docs/headless-gl.md).
render-fox: dirs
	$(FPC) -O2 $(RTLFLAGS) $(if $(MESA),-Fl$(MESA)/lib/x86_64-linux-gnu) \
	  $(if $(GLFWLIB),-Fl$(GLFWLIB)) \
	  -Fusrc -Futests -FU$(OUT)/tunits -FE$(OUT) -orender_fox tests/render_fox.pas
	$(if $(MESA),LD_LIBRARY_PATH=$(MESA)/lib/x86_64-linux-gnu:$(GLFWLIB)) \
	  EGL_PLATFORM=surfaceless ./$(OUT)/render_fox
	@python3 tools/bmp2png.py $(OUT)/fox.bmp $(OUT)/fox.png 2>/dev/null \
	  && echo "также сохранено: $(OUT)/fox.png" || true

# Проверка всех шейдеров компилятором GLSL от Khronos (если он установлен).
check-shaders:
	python3 tools/check_shaders.py

# Безэкранный прогон НАСТОЯЩЕГО OpenGL: контекст создаётся через EGL на
# платформе surfaceless, драйвером может быть программная Mesa (softpipe).
# Нужны libEGL и заголовки не нужны -- всё грузится динамически.
# Путь к своей сборке Mesa передаётся так:
#   make render-gl MESA=/путь/к/prefix
# Подробности и порядок сборки Mesa -- в docs/headless-gl.md
render-gl: dirs
	$(FPC) -O2 $(RTLFLAGS) $(if $(MESA),-Fl$(MESA)/lib/x86_64-linux-gnu) \
	  $(if $(GLFWLIB),-Fl$(GLFWLIB)) \
	  -Fusrc -Futests -FU$(OUT)/tunits -FE$(OUT) -orender_gl tests/render_gl.pas
	$(if $(MESA),LD_LIBRARY_PATH=$(MESA)/lib/x86_64-linux-gnu:$(GLFWLIB)) \
	  EGL_PLATFORM=surfaceless ./$(OUT)/render_gl
	@python3 tools/bmp2png.py $(OUT)/gl.bmp $(OUT)/gl.png 2>/dev/null \
	  && echo "также сохранено: $(OUT)/gl.png" || true

# Сверка кадра настоящего OpenGL с кадром программного растеризатора.
compare: preview render-gl
	python3 tools/compare_frames.py $(OUT)/gl.bmp $(OUT)/preview.bmp $(OUT)/diff.png

# Кадр, нарисованный программным растеризатором: та же сцена, та же камера
# и та же модель освещения, что и в шейдерах, но без видеокарты.
preview: dirs
	$(FPC) -O3 $(RTLFLAGS) -Fusrc -Futests -FU$(OUT)/tunits -FE$(OUT) -orender_preview tests/render_preview.pas
	./$(PREVBIN)
	@python3 tools/bmp2png.py $(OUT)/preview.bmp $(OUT)/preview.png 2>/dev/null \
	  && echo "также сохранено: $(OUT)/preview.png" || true

dirs:
	@mkdir -p $(OUT)/units $(OUT)/tunits

run: all
	./$(BIN)

clean:
	rm -rf $(OUT)

.PHONY: all portable debug test test-physics test-render test-raster test-anim preview render-gl render-fox check-shaders render-ragdoll render-ragdoll-gl compare dirs run clean
