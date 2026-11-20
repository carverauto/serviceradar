/**
 * The `Compression` plugin adds common compression code that other plugins can use.
 *
 * For information on how to include this plugin, see the {@tutorial building} tutorial.
 *
 * ## Beacon Parameters
 *
 * This plugin adds no parameters to the beacon.
 *
 * @class BOOMR.utils.Compression
 */
(function() {
  BOOMR = window.BOOMR || {};
  BOOMR.utils = BOOMR.utils || {};

  if (BOOMR.utils && BOOMR.utils.Compression) {
    return;
  }

  var self = BOOMR.utils.Compression = {};

  /**
   * Converts an object to URL-friendly JSON
   *
   * Adapted from https://github.com/Sage/jsurl
   *
   * Changes:
   *  Formatting
   *  Removal of Array.map and Object.map for compat with IE 6-8
   *  Change of str[i] syntax to str.charAt(i) for compat with IE 6-7
   *
   * @param {object} v Object to convert
   *
   * @returns {string} URL-friendly JSON
   * @memberof BOOMR.utils.Compression
   */
  self.jsUrl = function jsUrl(v) {
    /**
     * Encodes the specified string
     *
     * @param {string} s String
     *
     * @returns {string} Encoded string
     */
    function encode(s) {
      if (!/[^\w-.]/.test(s)) {
        // if the string is only made up of alpha-numeric, underscore,
        // dash or period, we can use it directly.
        return s;
      }

      // we need to escape other characters
      s = s.replace(/[^\w-.]/g, function(ch) {
        if (ch === "$") {
          return "!";
        }

        // use the character code for this one
        ch = ch.charCodeAt(0);

        if (ch < 0x100) {
          // if less than 256, use "*[2-char code]"
          return "*" + ("00" + ch.toString(16)).slice(-2);
        }
        else {
          // use "**[4-char code]"
          return "**" + ("0000" + ch.toString(16)).slice(-4);
        }
      });

      return s;
    }

    var tmpAry = [];

    switch (typeof v) {
    case "number":
      // for finite numbers, return "~[number]"
      return isFinite(v) ? "~" + v : "~null";

    case "string":
      // "~'[encoded string]"
      return "~'" + encode(v);

    case "boolean":
      // "~true" or "~false"
      return "~" + v;

    case "object":
      if (!v) {
        return "~null";
      }

      if (BOOMR.utils.isArray(v)) {
        // iterate instead of Array.map for compat
        for (var i = 0; i < v.length; i++) {
          if (i in v) {
            tmpAry[i] = self.jsUrl(v[i]) || "~null";
          }
        }

        return "~(" + (tmpAry.join("") || "~") + ")";
      }
      else {
        // iterate instead of Object.map for compat
        for (var key in v) {
          if (v.hasOwnProperty(key)) {
            var val = self.jsUrl(v[key]);
            // skip undefined and functions

            if (val) {
              tmpAry.push(encode(key) + val);
            }
          }
        }

        return "~(" + tmpAry.sort().join("~") + ")";
      }

    default:
      // function, undefined
      return undefined;
    }
  };


}());
