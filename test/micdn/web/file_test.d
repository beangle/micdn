module test.micdn.web.file_test;

import micdn.web.file;

@("web file range encode")
unittest {
  auto s = encodeAttachmentName("早上 好.txt");
  auto expected = `attachment; filename="%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt";`
                   ~` filename*=utf-8''%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt`;
  assert(s == expected);
  auto r1 = parseRange("0-1", 2);
  assert(r1 == [0, 1]);

  auto r2 = parseRange("9500-", 10_000);
  auto r3 = parseRange("-500", 10_000);
  assert(r2 == r3);

  auto r4 = parseRange("9500-100002", 10_000);
  assert(r2 == r4);

  auto r5 = parseRange("10000-100002", 10_000);
  assert(r5 == [9999, 9999]);
}
