#include <cwalk.h>
#include <limits.h>
#include <memory.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int normalize_forward_slashes(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_WINDOWS);

  input = "C:/this/is/a/test/path";
  strcpy(result, input);
  expected = "C:\\this\\is\\a\\test\\path";
  count = cwk_path_normalize(result, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_back_after_root(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_WINDOWS);

  input = "C:\\..\\this\\is\\a\\test\\path";
  strcpy(result, input);
  expected = "C:\\this\\is\\a\\test\\path";
  count = cwk_path_normalize(result, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_only_separators(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "////";
  strcpy(result, input);
  expected = "/";
  count = cwk_path_normalize(result, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_empty(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "test/..";
  strcpy(result, input);
  expected = ".";
  count = cwk_path_normalize(result, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_overlap(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "/var/./logs/.//test/..//..//////";
  strcpy(result, input);
  expected = "/var";
  count = cwk_path_normalize(result, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_mixed(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "/var/./logs/.//test/..//..//////";
  expected = "/var";
  count = cwk_path_normalize(input, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_remove_current(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "/var/././././";
  expected = "/var";
  count = cwk_path_normalize(input, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_double_separator(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "/var////logs//test/";
  expected = "/var/logs/test";
  count = cwk_path_normalize(input, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_terminated(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;
  size_t i, expected_size, n;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "/var/logs/test/../../";
  expected = "/var";
  expected_size = strlen(expected);

  memset(result, 1, sizeof(result));

  for (i = 0; i < 7; ++i) {
    count = cwk_path_normalize(input, result, i);

    if (i != 0 && expected_size < i) {
      n = expected_size;
    } else {
      n = i - 1;
    }

    if (count != strlen(expected) ||
        (i > 0 && (strncmp(result, expected, n) != 0 || result[n] != '\0'))) {
      return EXIT_FAILURE;
    }
  }

  return EXIT_SUCCESS;
}

int normalize_relative_too_far(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "rel/../../";
  expected = "..";
  count = cwk_path_normalize(input, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_absolute_too_far(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "/var/logs/test/../../../../../../";
  expected = "/";
  count = cwk_path_normalize(input, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_navigate_back(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "/var/logs/test/../../";
  expected = "/var";
  count = cwk_path_normalize(input, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int normalize_do_nothing(void)
{
  size_t count;
  char result[FILENAME_MAX];
  char *input, *expected;

  cwk_path_set_style(CWK_STYLE_UNIX);

  input = "/var";
  expected = "/var";
  count = cwk_path_normalize(input, result, sizeof(result));
  if (count != strlen(expected) || strcmp(result, expected) != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
