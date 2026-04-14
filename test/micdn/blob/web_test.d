/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

module micdn.blob.web_test;

import vibe.http.common : HTTPMethod;
import vibe.http.server : createTestHTTPServerRequest;
import vibe.inet.message : InetHeaderMap;
import vibe.inet.url : URL;

import micdn.blob.web;

@("blob referer same site as Host header")
unittest {
  InetHeaderMap h;
  h["Host"] = "example.com";
  h["Referer"] = "https://example.com/page";
  auto req = createTestHTTPServerRequest(URL("https://example.com/blob/a/x.jpg"), HTTPMethod.GET, h, null);
  assert(refererSameSiteAsRequest(req));

  h["Referer"] = "https://other.example/page";
  req = createTestHTTPServerRequest(URL("https://example.com/blob/a/x.jpg"), HTTPMethod.GET, h, null);
  assert(!refererSameSiteAsRequest(req));

  h["Host"] = "example.com";
  h["Referer"] = "https://example.com:443/foo";
  req = createTestHTTPServerRequest(URL("https://example.com/path"), HTTPMethod.GET, h, null);
  assert(refererSameSiteAsRequest(req));

  h["Host"] = "localhost:8080";
  h["Referer"] = "http://localhost:8080/cms";
  req = createTestHTTPServerRequest(URL("http://localhost:8080/blob/p/x.png"), HTTPMethod.GET, h, null);
  assert(refererSameSiteAsRequest(req));

  h["Host"] = "example.com:8443";
  h["Referer"] = "https://example.com/page";
  req = createTestHTTPServerRequest(URL("https://example.com/blob/a.jpg"), HTTPMethod.GET, h, null);
  assert(refererSameSiteAsRequest(req));

  InetHeaderMap h2;
  h2["Host"] = "a.com";
  h2["Referer"] = "";
  req = createTestHTTPServerRequest(URL("https://a.com/x"), HTTPMethod.GET, h2, null);
  assert(!refererSameSiteAsRequest(req));
}
