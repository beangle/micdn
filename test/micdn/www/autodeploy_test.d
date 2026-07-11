/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module test.micdn.www.autodeploy_test;

import micdn.www.autodeploy;

@("matchesAutoDeployZip compares absolute paths")
unittest {
  assert(matchesAutoDeployZip("/tmp/pkg.zip", "/tmp/pkg.zip"));
  assert(!matchesAutoDeployZip("/tmp/other.zip", "/tmp/pkg.zip"));
  assert(!matchesAutoDeployZip("", "/tmp/pkg.zip"));
}
