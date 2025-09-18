cwalktest_sources = files(
    'main.c',
    'absolute_test.c',
    'basename_test.c',
    'dirname_test.c',
    'extension_test.c',
    'guess_test.c',
    'intersection_test.c',
    'is_absolute_test.c',
    'is_relative_test.c',
    'join_test.c',
    'normalize_test.c',
    'relative_test.c',
    'root_test.c',
    'segment_test.c',
    'windows_test.c',
)

cwalktest = executable('cwalktest',
    sources: cwalktest_sources,
    dependencies: cwalk_dep,
)
test('cwalktest', cwalktest)
