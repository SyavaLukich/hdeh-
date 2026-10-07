SEARCH_DIR("/usr/lib/x86_64-linux-gnu/")
SEARCH_DIR("/lib64/")
SEARCH_DIR("/usr/lib64/")
SEARCH_DIR("./src/")
SEARCH_DIR("/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/")
SEARCH_DIR("/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl-objpas/")
SEARCH_DIR("/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl-extra/")
SEARCH_DIR("/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl-console/")
SEARCH_DIR("/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/")
INPUT(
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/si_prc.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/abitag.o
src/main.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/system.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/objpas.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/sysutils.o
src/umath.o
src/uglfw.o
src/ugl.o
src/umesh.o
src/urender.o
src/ugjk.o
src/uphysics.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/linux.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/unix.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/errors.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/sysconst.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/unixtype.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/baseunix.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/unixutil.o
/home/user/tools/pandroid/FreePascal/fpc/lib/fpc/3.3.1/units/x86_64-linux/rtl/math.o
)
INPUT(
-lglfw
)
SECTIONS
{
  .fpcdata           :
  {
    KEEP (*(.fpc .fpc.n_version .fpc.n_links))
  }
  .threadvar : { *(.threadvar .threadvar.* .gnu.linkonce.tv.*) }
}
INSERT AFTER .data;
