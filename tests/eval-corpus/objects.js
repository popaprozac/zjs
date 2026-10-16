var point = { x: 1, y: 2, "quoted key": 3, 42: "answer" };
point.z = point.x + point.y;
point["w"] = point["quoted key"] * 2;
point.x += 10;
var nested = { inner: { deep: { value: 7 } }, list: [1, 2, 3] };
var sum = point.x + point.y + point.z + point.w + nested.inner.deep.value + nested.list[1] + nested.list.length;
sum + ":" + point[42] + ":" + typeof point + ":" + typeof point.missing + ":" + point.missing;
