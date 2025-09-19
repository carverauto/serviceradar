#include <cwalk.h>
#include <stdlib.h>

int intersection_skipped_end(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);

  if (cwk_path_get_intersection("/test/foo/har/../", "/test/foo/ho") != 9) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_relative_other(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);

  if (cwk_path_get_intersection("/test/foo/har", "/test/abc/../foo/bar") != 9) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_relative_base(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);

  if (cwk_path_get_intersection("/test/abc/../foo/bar", "/test/foo/har") !=
      16) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_one_root_only(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (cwk_path_get_intersection("C:/abc/test.txt", "C:/") != 3) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_same_roots(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (cwk_path_get_intersection("C:/abc/test.txt", "C:/def/test.txt") != 3) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_relative_absolute_mix(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);

  if (cwk_path_get_intersection("/test/abc.txt", "test/abc.txt") != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_unequal_roots(void)
{
  cwk_path_set_style(CWK_STYLE_WINDOWS);

  if (cwk_path_get_intersection("C:/test/abc.txt", "D:/test/abc.txt") != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_empty(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);

  if (cwk_path_get_intersection("/", "") != 0) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_double_separator(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);
  if (cwk_path_get_intersection("/this///is/a//test", "/this//is/a///file") !=
      12) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_trailing_separator(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);
  if (cwk_path_get_intersection("/this/is/a/test", "/this/is/a/") != 10) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_truncated(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);
  if (cwk_path_get_intersection("/this/is/a/test", "/this/is/a") != 10) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int intersection_simple(void)
{
  cwk_path_set_style(CWK_STYLE_UNIX);
  if (cwk_path_get_intersection("/this/is/a/test", "/this/is/a/string") != 10) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
