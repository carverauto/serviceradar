#include <cwalk.h>
#include <memory.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int root_change_without_root(void)
{
  size_t length;
  char buffer[FILENAME_MAX] = "hello\\world.txt";

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  length = cwk_path_change_root(buffer, "D:\\", buffer,
    sizeof(buffer));

  if (length != 18) {
    return EXIT_FAILURE;
  }

  if (strcmp(buffer, "D:\\hello\\world.txt") != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_change_overlapping(void)
{
  size_t length;
  char buffer[FILENAME_MAX] = "C:\\hello\\world.txt";

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  length = cwk_path_change_root(buffer, "D:\\path\\", buffer,
    sizeof(buffer));

  if (length != 23) {
    return EXIT_FAILURE;
  }

  if (strcmp(buffer, "D:\\path\\hello\\world.txt") != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_change_separators(void)
{
  size_t length;
  char buffer[FILENAME_MAX];

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  length = cwk_path_change_root("C:\\hello\\world.txt", "D:\\path\\", buffer,
    sizeof(buffer));

  if (length != 23) {
    return EXIT_FAILURE;
  }

  if (strcmp(buffer, "D:\\path\\hello\\world.txt") != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_change_empty(void)
{
  size_t length;
  char buffer[FILENAME_MAX];

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  length = cwk_path_change_root("C:\\hello\\world.txt", "", buffer,
    sizeof(buffer));

  if (length != 15) {
    return EXIT_FAILURE;
  }

  if (strcmp(buffer, "hello\\world.txt") != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_change_simple(void)
{
  size_t length;
  char buffer[FILENAME_MAX];

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  length = cwk_path_change_root("C:\\hello\\world.txt", "D:\\", buffer,
    sizeof(buffer));

  if (length != 18) {
    return EXIT_FAILURE;
  }

  if (strcmp(buffer, "D:\\hello\\world.txt") != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_relative_windows(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("..\\hello\\world.txt", &length);

  if (length != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_relative_drive(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("C:test.txt", &length);

  if (length != 2) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_device_question_mark(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("\\\\?\\mydevice\\test", &length);

  if (length != 4) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_device_dot(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("\\\\.\\mydevice\\test", &length);

  if (length != 4) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_device_unc(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("\\\\.\\UNC\\LOCALHOST\\c$\\temp\\test-file.txt", &length);

  if (length != 4) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_unc(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("\\\\server\\folder\\data", &length);

  if (length != 16) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_absolute_drive(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("C:\\test.txt", &length);

  if (length != 3) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_unix_drive(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_UNIX);
  cwk_path_get_root("C:\\test.txt", &length);

  if (length != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_unix_backslash(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_UNIX);
  cwk_path_get_root("\\folder\\", &length);

  if (length != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_windows_slash(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("/test.txt", &length);

  if (length != 1) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_windows_backslash(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_WINDOWS);
  cwk_path_get_root("\\test.txt", &length);

  if (length != 1) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_relative(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_UNIX);
  cwk_path_get_root("test.txt", &length);

  if (length != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int root_absolute(void)
{
  size_t length;

  cwk_path_set_style(CWK_STYLE_UNIX);
  cwk_path_get_root("/test.txt", &length);

  if (length != 1) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
