# Associative Arrays Again?!
[Official git repository](https://git.sleeping.town/ichordev/aaagain)

A copy of the associative array implementation from DRuntime, but with no reliance on runtime type information, and support for allocating using [custom allocators](https://code.dlang.org/packages/memterface)!

The interface is almost identical to the built-in associative array, but with a few small differences:
```d
import aaagain;
SomeAllocator alloc;
SomeOtherAllocator alloc2;

//AA must be explicitly allocated:
auto myAA = AA(string, int, SomeAllocator)(alloc);
/*
Alternative syntax: you can use one allocator for the AA itself,
and a different allocator for the AA's entries/buckets:
*/
auto myAA = AA!(string, int, SomeAllocator)(
	aaAllocator: alloc,
	bucketAllocator: alloc2,
);

myAA["twenty"] = 20;
assert("twenty" in myAA);
assert(*("twenty" in myAA) == 20);
assert(myAA["twenty"] == 20);

//`opApply` is not supported. Use `byKey`, `byValue`, or `byKeyValue` instead:
foreach(key; myAA.byKey)
	assert(key == 20);
foreach(value; myAA.byValue)
	assert(value == 20);

//`get` and `require` take a function/delegate instead of a `lazy` value:
assert(myAA.get("fourty", () => 40) == 40);
assert(myAA.require("twenty", () => 21) == 20);
myAA.update(
	key: "fifty",
	create: () => 50,
	update: (int _) => 51,
);
assert(myAA["fifty"] == 50);

//The `update` delegate can take its parameter by `ref` and return `void`:
myAA.update(
	key: "fifty",
	create: () => 50,
	update: (ref int i){ i = 51; },
);
assert(myAA["fifty"] == 51);

//Associative array literals are constructed with `aaLiteral`:
{
	auto aaCmp = aaLiteral(alloc, alloc2, "twenty",20, "fifty",51);
	assert(myAA == aaCmp);
	aaCmp.dispose(alloc);
}

myAA.remove("fifty");

import memterface.ctor: dispose;

//there is `.getKeys` instead of `.keys`, which uses manual memory management:
auto keyArray = myAA.getKeys(alloc2);
assert(keyArray == ["twenty"]);
alloc2.dispose(keyArray);

//Likewise for `.values`:
auto valueArray = myAA.getValues(alloc2);
assert(valueArray == [20]);
alloc2.dispose(valueArray);

//These ranges yield `ref const` item instead of `ref` for safety reasons:
foreach(key; myAA.byKey){
	assert(key == "twenty");
}
foreach(value; myAA.byValue){
	assert(value == 20);
}
foreach(item; myAA.byKeyValue){
	assert(item.key == "twenty");
	assert(item.value == 20);
}

//Must explicitly destroy AA with the same allocator that allocated it:
myAA.dispose(alloc);
```

The `AA` type is just a container for a pointer, just like the built-in associative array:
```d
AA!(string, int) aa;
static assert(aa.sizeof == int[string].sizeof);
auto aa2 = aa;
aa["one"] = 1;
assert("one" in aa2);
```

Advanced users can tinker with the parameters of the associative array by supplying the `AAParams` template parameter:
```d
AA!(K, V, Allocator, AAParams(
	//numerator,denominator pairs for the grow/shrink thresholds:
	grow: 4, 5,
	shrink: 1, 8,
	//the growth factor:
	growFactor: 4,
));
```
