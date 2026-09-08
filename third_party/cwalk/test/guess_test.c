#include <cwalk.h>
#include <stdlib.h>

int guess_empty_string(void)
{
  if (cwk_path_guess_style("") != CWK_STYLE_UNIX) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int guess_unguessable(void)
{
  if (cwk_path_guess_style("myfile") != CWK_STYLE_UNIX) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int guess_extension(void)
{
  if (cwk_path_guess_style("myfile.txt") != CWK_STYLE_WINDOWS) {
    return EXIT_FAILURE;
  }

  if (cwk_path_guess_style("/a/directory/myfile.txt") != CWK_STYLE_UNIX) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int guess_hidden_file(void)
{
  if (cwk_path_guess_style(".my_hidden_file") != CWK_STYLE_UNIX) {
    return EXIT_FAILURE;
  }

  if (cwk_path_guess_style(".my_hidden_file.txt") != CWK_STYLE_UNIX) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int guess_unix_separator(void)
{
  if (cwk_path_guess_style("/directory/other") != CWK_STYLE_UNIX) {
    return EXIT_FAILURE;
  }

  if (cwk_path_guess_style("/directory/other.txt") != CWK_STYLE_UNIX) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int guess_windows_separator(void)
{
  if (cwk_path_guess_style("\\directory\\other") != CWK_STYLE_WINDOWS) {
    return EXIT_FAILURE;
  }
  if (cwk_path_guess_style("\\directory\\.other") != CWK_STYLE_WINDOWS) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int guess_unix_root(void)
{
  if (cwk_path_guess_style("/directory") != CWK_STYLE_UNIX) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

int guess_windows_root(void)
{
  if (cwk_path_guess_style("C:\\test") != CWK_STYLE_WINDOWS) {
    return EXIT_FAILURE;
  }

  if (cwk_path_guess_style("C:/test") != CWK_STYLE_WINDOWS) {
    return EXIT_FAILURE;
  }

  if (cwk_path_guess_style("C:test") != CWK_STYLE_WINDOWS) {
    return EXIT_FAILURE;
  }

  if (cwk_path_guess_style("C:/.test") != CWK_STYLE_WINDOWS) {
    return EXIT_FAILURE;
  }

  if (cwk_path_guess_style("C:/folder/.test") != CWK_STYLE_WINDOWS) {
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
