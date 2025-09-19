#include <cwalk.h>
#include <stdlib.h>

int is_absolute_relative_windows(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (cwk_path_is_absolute("..\\hello\\world.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_relative_drive(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (cwk_path_is_absolute("C:test.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_device_question_mark(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (!cwk_path_is_absolute("\\\\?\\mydevice\\test")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_device_dot(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_is_absolute("\\\\.\\mydevice\\test");

  if (!cwk_path_is_absolute("\\\\.\\mydevice\\test")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_device_unc(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (!cwk_path_is_absolute("\\\\.\\UNC\\LOCALHOST\\c$\\temp\\test-file.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_unc(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (!cwk_path_is_absolute("\\\\server\\folder\\data")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_absolute_drive(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (!cwk_path_is_absolute("C:\\test.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_unix_drive(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);

  if (cwk_path_is_absolute("C:\\test.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_unix_backslash(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);

  if (cwk_path_is_absolute("\\folder\\")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_windows_slash(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (!cwk_path_is_absolute("/test.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_windows_backslash(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (!cwk_path_is_absolute("\\test.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_relative(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);

  if (cwk_path_is_absolute("test.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_absolute(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);
  if (!cwk_path_is_absolute("/test.txt")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_root(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);
  if (!cwk_path_is_absolute("/")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int is_absolute_dir(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);
  if (!cwk_path_is_absolute("/dir")) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
