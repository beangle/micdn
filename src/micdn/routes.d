/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

module micdn.routes;
/// 内置 HTTP 挂载路径（不在 micdn.xml 中配置）。`<doc location>` 仍由配置指定。

immutable string mountMaven = "/maven";
immutable string mountNpm = "/npm";
immutable string mountStatic = "/static";
immutable string mountBlob = "/blob";
immutable string mountS3 = "/s3";
