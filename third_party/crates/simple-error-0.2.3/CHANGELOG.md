# Changelog

This project roughly adheres to [Semantic Versioning](http://semver.org/). For 0.x.y releases, `x` is the major version in semver, while `y` is the minor version.

## 0.2.3 - 2021-01-14

* Add convenience macro `map_err_with`

## 0.2.2 - 2020-08-16

* Support constructing from format string using `simple_error` macro

## 0.2.1 - 2019-07-03

* Fix 1.36.0 inference breakage

## 0.2.0 - 2019-05-29

* Republish 0.1.13 as 0.2.0

## 0.1.13 - 2018-12-07 (yanked)

* Make `try_with`, `require_with` and `bail` work more consistent with `try`

This version has been yanked due to breaking compatibility to 0.1.12. It will be republished as 0.2.0.

## 0.1.12 - 2018-10-11

* Make `try_with`, `require_with` and `bail` work without requiring `using simple_error::SimpleError`

## 0.1.11 - 2018-03-31

* Support format string in `try_with` and `require_with`

## 0.1.10 - 2017-10-15

* Add `as_str`

## 0.1.9 - 2017-05-05

* Support `bail` macro with string slice

## 0.1.8 - 2017-05-04

* Add `bail` macro

## 0.1.7 - 2017-03-14

* Add `SimpleResult`

## 0.1.6 - 2017-01-08

* Add `require_with` macro
* Support `String` in `SimpleError::with`

## 0.1.5 - 2017-01-07

* Use inline to improve LTO

## 0.1.4 - 2016-06-04

* Documentation fix for broken doc test

## 0.1.3 - 2016-06-04

* Add `try_with` macro

## 0.1.2 - 2016-04-24

* Add `SimpleError::with`

## 0.1.1 - 2016-03-24

### Project

* Add badges
* Add documentations

## 0.1.0 - 2016-03-24

First release
