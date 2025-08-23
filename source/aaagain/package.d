/**
Implementation of associative arrays.

Copyright: Copyright Digital Mars 2000 - 2015
License: [Boost License 1.0](www.boost.org/LICENSE_1_0.txt)
Authors: Aya Partridge, Martin Nowak
*/
module aaagain;

import core.exception, core.lifetime;
import std.algorithm.comparison: min;
import std.range: iota;
import memterface.allocator.gc, memterface.ctor, memterface.iface;

struct AAParams{
	///Grow threshold.
	size_t grow=4, growDenominator=5;
	///Shrink threshold.
	size_t shrink=1, shrinkDenominator=8;
	///Growth factor.
	uint growFactor=4;
}

//magic hash constants to distinguish empty, deleted, and filled buckets
private enum HASH_EMPTY = 0;
private enum HASH_DELETED = 0x1;
private enum HASH_FILLED_MARK = size_t(1) << 8 * size_t.sizeof - 1;

enum isAA(T) = is(T: AA!(K, V, BA, EA, params), K, V, BA, EA, AAParams params);
enum isAA(T, Key, Value) = is(T: AA!(K, V, BA, EA, params), K: Key, V: Value, BA, EA, AAParams params);

struct AA(K, V, BucketAlloc=GCAllocator, EntryAlloc=GCAllocator, AAParams params=AAParams.init)
if(isAllocator!BucketAlloc && isAllocator!EntryAlloc){
	alias Key = K;
	alias Value = V;
	alias BucketAllocator = BucketAlloc;
	alias EntryAllocator = EntryAlloc;
	
	static assert(!__traits(hasPostblit, Key), "Postblits are unsupported");
	static assert(!__traits(hasPostblit, Value), "Postblits are unsupported");
	
	static assert(params.growFactor * params.shrink * params.growDenominator < params.grow * params.shrinkDenominator,
		"Growing the AA doubles its size, so the shrink threshold must be smaller than half the grow threshold to have a hysteresis");
	
	enum initialLoad = (params.growDenominator * params.shrink + params.grow * params.shrinkDenominator) / 2;
	enum initialLoadDenominator = params.shrinkDenominator * params.growDenominator;
	
	alias Bucket = AABucket!(Key, Value);
	
	alias Entry = Bucket.Entry;
	
	private struct Impl{
		enum initialBucketCount = params.growFactor * 2;
		
		private{
			BucketAllocator bucketAllocator;
			EntryAllocator entryAllocator;
			Bucket[] buckets;
			uint used, deleted;
			uint firstUsed;
		}
		
		this(ref BucketAllocator bucketAllocator, ref EntryAllocator entryAllocator, size_t size=initialBucketCount){
			this.bucketAllocator = bucketAllocator;
			this.entryAllocator = entryAllocator;
			this.buckets = this.bucketAllocator.newArray!Bucket(size);
			this.firstUsed = cast(uint)buckets.length;
		}
		
		pragma(inline,true){
			void assertWasInit() const nothrow @nogc pure @safe{
				assert(&this !is null && buckets.length > 0, "AA must be allocated before being used");
			}
			
			@property size_t length() const nothrow @nogc pure @safe{
				assert(used >= deleted);
				return used - deleted;
			}
			
			@property bool empty() const nothrow @nogc pure @safe =>
				&this is null || !this.length;
			
			@property size_t mask() const nothrow @nogc pure @safe =>
				buckets.length - 1;
		}
		
		size_t calcHash(scope ref const Key key) inout{
			static size_t mix(size_t hash) nothrow @nogc pure @safe{
				//final mix function of MurmurHash2
				enum m = 0x5bd1e995;
				hash ^= hash >> 13;
				hash *= m;
				hash ^= hash >> 15;
				return hash;
			}
			immutable hash = key.hashOf();
			//highest bit is set to distinguish empty/deleted from filled buckets
			return mix(hash) | HASH_FILLED_MARK;
		}
		
		//find the first slot to insert a value with hash
		inout(Bucket)* findSlotInsert(size_t hash) inout nothrow @nogc pure @safe{
			for(size_t i = hash & mask, j = 1;; j++){
				if(!buckets[i].filled)
					return &buckets[i];
				i = (i + j) & mask;
			}
		}
		
		//look up a key
		inout(Bucket)* findSlotLookup(size_t hash, scope ref const Key key) inout{
			for(size_t i = hash & mask, j = 1;; j++){
				if(buckets[i].hash == hash && key == buckets[i].entry.key)
					return &buckets[i];
				else if(buckets[i].empty)
					return null;
				i = (i + j) & mask;
			}
		}
		
		void grow() nothrow pure{
			/* if there are so many deleted entries that growing would push us
			below the shrink threshold, we just purge deleted entries instead */
			if(this.length * params.shrinkDenominator < params.growFactor * buckets.length * params.shrink)
				resize(buckets.length);
			else
				resize(params.growFactor * buckets.length);
		}
		
		void shrink() nothrow pure{
			if(buckets.length > initialBucketCount)
				resize(buckets.length / params.growFactor);
		}
		
		void resize(size_t newSize){
			auto oldBuckets = buckets;
			buckets = this.bucketAllocator.newArray!Bucket(newSize);
			
			foreach(ref oldBucket; oldBuckets[firstUsed..$])
				if(oldBucket.filled)
					*findSlotInsert(oldBucket.hash) = oldBucket;
			
			firstUsed = 0;
			used -= deleted;
			deleted = 0;
			(() nothrow @trusted => this.bucketAllocator.dispose(oldBuckets))(); //safe to free b/c impossible to reference
		}
		
		inout(Value)* inX(scope ref const Key key) inout{
			if(empty) return null;
			
			immutable hash = calcHash(key);
			if(auto p = findSlotLookup(hash, key)){
				return &p.entry.value;
			}
			return null;
		}
		
		auto getX(scope ref const Key key){
			static struct Result{
				Value* value;
				bool found=false;
			}
			assertWasInit();
			//get hash and bucket for key
			immutable hash = calcHash(key);
			
			//found a value => return it
			if(auto p = findSlotLookup(hash, key)){
				return Result(&p.entry.value, found: true);
			}
			
			auto p = findSlotInsert(hash);
			if(p.deleted){
				--this.deleted;
			}else if(++this.used * params.growDenominator > buckets.length * params.grow){ //check load factor and possibly grow
				grow();
				p = findSlotInsert(hash);
				assert(p.empty);
			}
			
			//update search cache and allocate entry
			firstUsed = min(firstUsed, (() @trusted => cast(uint)(p - buckets.ptr))());
			p.hash = hash;
			p.entry = this.entryAllocator.constructNew!Entry(key);
			//return pointer to value
			return Result(&p.entry.value);
		}
	}
	Impl* impl;
	
	/**
	Allocate a new associative array. `aaAllocator` must be used to `dispose` of this associative array later.
	
	`bucketAllocator` and `entryAllocator` can only be the same if they are a global allocator.
	
	Params:
		aaAllocator = Used to allocate the associative array itself.
		bucketAllocator = Used to allocate the buckets within the associative array.
		entryAllocator = Used to allocate the entries within the associative array.
	*/
	this(AAAllocator)(scope auto ref AAAllocator aaAllocator, auto ref BucketAllocator bucketAllocator, auto ref EntryAllocator entryAllocator)
	if(isAllocator!AAAllocator){
		static if(__traits(compiles, BucketAllocator.init == EntryAllocator.init) && !isGlobal!BucketAllocator && !isGlobal!EntryAllocator){
			assert(bucketAllocator != entryAllocator, "The allocators for buckets and for entries must be separate instances");
		}
		this.impl = aaAllocator.constructNew!Impl(bucketAllocator, entryAllocator);
	}
	
	static if(is(BucketAllocator: EntryAllocator) && isGlobal!BucketAllocator){
		this(AAAllocator)(auto ref AAAllocator aaAllocator, auto ref BucketAllocator bucketEntryAllocator)
		if(isAllocator!AAAllocator){
			this.impl = aaAllocator.constructNew!Impl(bucketEntryAllocator, bucketEntryAllocator);
		}
	}
	
	/**
	Destroy & deallocate this associative array, which must have been previously allocated with `allocator`.
	*/
	void dispose(AAAllocator)(scope auto ref AAAllocator aaAllocator){
		impl.assertWasInit();
		clear();
		impl.bucketAllocator.dispose(impl.buckets);
		aaAllocator.dispose(impl);
	}
	
	pragma(inline,true){
		@property size_t length() const nothrow @nogc pure @safe =>
			impl !is null ? impl.length : 0;
		
		bool opCast(T: bool)() const nothrow @nogc pure @safe =>
			impl !is null;
		
		inout(Value)* opBinaryRight(string op: "in")(scope auto ref const Key key) inout =>
			impl.inX(key);
		
		inout(Value) opIndex()(scope auto ref const Key key) inout{
			if(auto ret = impl.inX(key))
				return *ret;
			onRangeError();
		}
		
		Value opIndexAssign()(auto ref Value value, scope auto ref const Key key) nothrow =>
			*impl.getX(key).value = value;
	}
	
	bool opEquals(AAT)(scope const AAT rhs) const
	if(isAA!(AAT, Key, Value)){
		if(impl.empty){
			return rhs.impl.empty;
		}else if(impl is cast(void*)rhs.impl || impl.length != rhs.impl.length){
			return true;
		}
		foreach(b1; impl.buckets){ //compare the entries:
			if(!b1.filled) continue;
			auto pb2 = rhs.impl.findSlotLookup(b1.hash, b1.entry.key);
			if(pb2 is null || b1.entry.value != pb2.entry.value)
				return false;
		}
		return true;
	}
	
	size_t hashOf() const nothrow{
		if(impl.empty) return 0;
		
		size_t hash;
		foreach(bucket; impl.buckets){
			//use addition here, so that hash is independent of element order
			if(bucket.filled)
				hash += object.hashOf(
					bucket.entry.value.hashOf(),
					bucket.entry.key.hashOf(),
				);
		}
		return hash;
	}
	
	bool remove()(scope auto ref const Key key){
		if(!impl.empty){
			if(auto p = impl.findSlotLookup(impl.calcHash(key), key)){
				//clear entry
				p.hash = HASH_DELETED;
				impl.entryAllocator.dispose(p.entry);
				p.entry = null;
				
				++impl.deleted;
				if(impl.length * params.shrinkDenominator < impl.buckets.length * params.shrink)
					impl.shrink();
				
				return true;
			}
		}
		return false;
	}
	
	/**
	Returns: An array allocated with `allocator`, the elements of which are the keys in the associative array.
	
	The returned array must later be deallocated using the same `allocator`.
	*/
	inout(Key[]) getKeys(Allocator)(auto ref Allocator allocator) inout{
		if(impl.empty) return null;
		
		auto res = allocator.newArray!Key(impl.length);
		void[] pKey = res;
		foreach(bucket; impl.buckets[impl.firstUsed .. $]){
			if(!bucket.filled) continue;
			pKey[0..bucket.entry.key.sizeof] = cast(void[])((&bucket.entry.key)[0..1]);
			pKey = pKey[bucket.entry.key.sizeof..$];
		}
		return cast(inout(Key[]))res;
	}
	
	/**
	Returns: An array allocated with `allocator`, the elements of which are the values in the associative array.
	
	The returned array must later be deallocated using the same `allocator`.
	*/
	inout(Value[]) getValues(Allocator)(auto ref Allocator allocator) inout{
		if(impl.empty) return null;
		
		auto res = allocator.newArray!Value(this.length);
		void[] pVal = res;
		foreach(bucket; impl.buckets[impl.firstUsed..$]){
			if(!bucket.filled) continue;
			pVal[0..bucket.entry.value.sizeof] = cast(void[])((&bucket.entry.value)[0..1]);
			pVal = pVal[bucket.entry.value.sizeof..$];
		}
		return cast(inout(Value[]))res;
	}
	
	AA rehash() nothrow{
		if(!impl.empty)
			impl.resize(nextPow2(initialLoadDenominator * this.length / initialLoad));
		return this;
	}
	
	void clear() nothrow @nogc pure @trusted{
		if(impl.empty) return;
		
		import core.stdc.string: memset;
		//clear all data, but don't change bucket array length
		foreach(ref bucket; impl.buckets[impl.firstUsed..$]){
			if(bucket.filled)
				impl.entryAllocator.dispose(bucket.entry);
		}
		memset(&impl.buckets[impl.firstUsed], 0, (impl.buckets.length - impl.firstUsed) * Bucket.sizeof);
		impl.deleted = impl.used = 0;
		impl.firstUsed = cast(uint)impl.buckets.length;
	}
	
	private static struct Range{
		const(Impl)* impl;
		size_t idx;
		
		this(return scope const(Impl)* aaImpl) nothrow @nogc pure @safe{
			if(!aaImpl.empty){
				this.impl = aaImpl;
				foreach(i; impl.firstUsed..impl.buckets.length){
					if(impl.buckets[i].filled){
						this.idx = i;
						return;
					}
				}
				this.idx = impl.buckets.length;
			}
		}
		
		pragma(inline,true)
		@property bool empty() const nothrow @nogc pure @safe =>
			impl is null || idx >= impl.buckets.length;
		
		const(Key)* frontKey() const nothrow @nogc pure @safe{
			assert(!empty);
			if(idx >= impl.buckets.length)
				return null;
			return &impl.buckets[idx].entry.key;
		}
		
		const(Value)* frontValue() const nothrow @nogc pure @safe{
			assert(!empty);
			if(idx >= impl.buckets.length)
				return null;
			auto entry = impl.buckets[idx].entry;
			return entry ? &entry.value : null;
		}
		
		void popFront() nothrow @nogc pure @safe{
			if(idx >= impl.buckets.length) return;
			for(++idx; idx < impl.buckets.length; ++idx){
				if(impl.buckets[idx].filled)
					break;
			}
		}
	}
	
	@property byKey() nothrow @nogc pure @safe{
		static struct Result{
			private Range range;
			
			pragma(inline,true){
				@property bool empty() const nothrow @nogc pure @safe => range.empty;
				@property ref const(Key) front() const nothrow @nogc pure @safe => *range.frontKey;
				void popFront() nothrow @nogc pure @safe{ range.popFront(); }
				@property Result save() nothrow @nogc pure => this;
			}
		}
		return Result(Range(impl));
	}
	
	@property byValue() inout nothrow @nogc pure @safe{
		static struct Result{
			private Range range;
			
			pragma(inline,true){
				@property bool empty() const nothrow @nogc pure @safe => range.empty;
				@property ref const(Value) front() const nothrow @nogc pure @safe => *range.frontValue;
				void popFront() nothrow @nogc pure @safe{ range.popFront(); }
				@property Result save() nothrow @nogc pure => this;
			}
		}
		return Result(Range(impl));
	}
	
	@property byKeyValue() nothrow @nogc pure @safe{
		static struct Result{
			private Range range;
			
			static struct Pair{
				/* We save the pointers here so that the Pair we return
				won't mutate when Result.popFront is called afterwards. */
				private const(Key)* keyPtr;
				private const(Value)* valPtr;
				
				pragma(inline,true){
					@property ref const(Key) key() const nothrow @nogc pure @safe => *keyPtr;
					@property ref const(Value) value() const nothrow @nogc pure @safe => *valPtr;
				}
			}
			pragma(inline,true){
				@property bool empty() const nothrow @nogc pure @safe => range.empty;
				@property auto front() const nothrow @nogc pure @safe => Pair(range.frontKey, range.frontValue);
				void popFront() nothrow @nogc pure @safe{ range.popFront(); }
				@property Result save() nothrow @nogc pure => this;
			}
		}
		
		return Result(Range(impl));
	}
	
	inout(Value) get(D)(scope auto ref const Key key, scope D defaultValue) inout
	if(is(typeof(defaultValue()): inout(Value))){
		auto valuePtr = impl.inX(key);
		return valuePtr ? *valuePtr : defaultValue();
	}
	
	ref Value require()(scope auto ref const Key key) =>
		*impl.getX(key).value;
	
	ref Value require(V)(scope auto ref const Key key, scope V value)
	if(is(typeof(value()): Value)){
		auto p = impl.getX(key);
		if(p.found){
			return *p.value;
		}else{
			/* Not `return (*p = value)`, since if `=` is overloaded
			this might not return a ref to the left-hand side. */
			*p.value = value();
			return *p.value;
		}
	}
	
	void update(C, U)(Key key, scope C create, scope U update)
	if(is(typeof(create()): Value) && (
		is(typeof(update(Value.init)): Value) ||
		(){ auto valueRef = Value.init; return is(typeof(update(valueRef)) == void); }()
	)){
		auto p = impl.getX(key);
		if(p.found){
			static if(is(typeof(update(*p.value)): Value))
				*p.value = update(*p.value);
			else
				update(*p.value);
		}else{
			*p.value = create();
		}
	}
}

struct AAEntry(K, V){
	const K key;
	V value;
}

struct AABucket(K, V){
	alias Entry = AAEntry!(K, V);
	size_t hash = HASH_EMPTY;
	Entry* entry;
	
	pragma(inline,true) nothrow @nogc pure @safe{
		@property bool empty() const => hash == HASH_EMPTY;
		@property bool deleted() const => hash == HASH_DELETED;
		@property bool filled() const => cast(ptrdiff_t)hash < 0;
	}
}

/**
Allocate a new associative array. `aaAllocator` must be used to `dispose` of this associative array later.

`bucketAllocator` and `entryAllocator` can only be the same if they are a global allocator.

Params:
	aaAllocator = Used to allocate the associative array itself.
	bucketAllocator = Used to allocate the buckets within the associative array.
	entryAllocator = Used to allocate the entries within the associative array.
*/
pragma(inline,true)
auto newAA(Key, Value, AAParams params=AAParams.init, AAAllocator, BucketAllocator, EntryAllocator)(
	auto ref AAAllocator aaAllocator, auto ref BucketAllocator bucketAllocator, auto ref EntryAllocator entryAllocator,
) =>
	AA!(Key, Value, BucketAllocator, EntryAllocator, params)(aaAllocator, bucketAllocator, entryAllocator);

unittest{
	auto aa = newAA!(char[], long)(GCAllocator(), GCAllocator(), GCAllocator());
}

/**
Allocate a new associative array. `aaAllocator` must be used to `dispose` of this associative array later.

`bucketEntryAllocator` must be a global allocator.

Params:
	aaAllocator = Used to allocate the associative array itself.
	bucketEntryAllocator = Used to allocate the buckets & entries within the associative array.
*/
pragma(inline,true)
auto newAA(Key, Value, AAParams params=AAParams.init, AAAllocator, BucketEntryAllocator)(
	auto ref AAAllocator aaAllocator, auto ref BucketEntryAllocator bucketEntryAllocator,
){
	static assert(isGlobal!BucketEntryAllocator, "`bucketEntryAllocator` must be a global allocator");
	return AA!(Key, Value, BucketEntryAllocator, BucketEntryAllocator, params)(aaAllocator, bucketEntryAllocator, bucketEntryAllocator);
}
unittest{
	auto aa = newAA!(char[], long)(GCAllocator(), GCAllocator());
}

/**
Construct an associative array from pairs of keys and values,
allocated with `aaAllocator`, `bucketAllocator`, and `entryAllocator`.

Returns: A new associative array, or `null` if `keysValues` is empty.
*/
auto makeAA(AAParams params=AAParams.init, AAAllocator, BucketAllocator, EntryAllocator, KVs...)(
	auto ref AAAllocator aaAllocator, auto ref BucketAllocator bucketAllocator, auto ref EntryAllocator entryAllocator, auto ref KVs keysValues,
) nothrow{
	static assert((KVs.length & 1) == 0, "Must provide an even number of arguments to `keysValues`");
	static if(KVs.length >= 2){
		alias Key = KVs[0];
		alias Value = KVs[1];
		alias AAT = AA!(Key, Value, BucketAllocator, EntryAllocator, params);
		AAT aa;
		aa.impl = aaAllocator.constructNew!(AAT.Impl)(
			bucketAllocator,
			entryAllocator,
			nextPow2(AAT.initialLoadDenominator * (KVs.length/2) / AAT.initialLoad),
		);
		
		uint actualLength = 0;
		size_t hash;
		AAT.Bucket* p;
		static foreach(ind; iota(0, KVs.length, 2)){
			//keysValues[ind+0] == key, keysValues[ind+1] == value
			hash = aa.impl.calcHash(keysValues[ind+0]);
			
			p = aa.impl.findSlotLookup(hash, keysValues[ind+0]);
			if(p is null){
				p = aa.impl.findSlotInsert(hash);
				p.hash = hash;
				p.entry = aa.impl.entryAllocator.constructNew!(AAT.Entry)(keysValues[ind+0], keysValues[ind+1]);
				aa.impl.firstUsed = min(aa.impl.firstUsed, (() @trusted => cast(uint)(p - aa.impl.buckets.ptr))());
				actualLength++;
				moveEmplace(keysValues[ind+1], p.entry.value);
			}else{ //key appears more than once
				//destroy existing value before overwriting it
				move(keysValues[ind+1], p.entry.value);
			}
		}
		aa.impl.used = actualLength;
		return aa;
	}else return null;
}

unittest{
	import memterface.allocator.malloc;
	
	CAllocator cAlloc;
	GCAllocator gcAlloc;
	auto aa = AA!(string, int, CAllocator, GCAllocator)(
		aaAllocator: gcAlloc,
		bucketAllocator: cAlloc,
		entryAllocator: gcAlloc,
	);
	
	aa["twenty"] = 20;
	assert("twenty" in aa);
	assert(*("twenty" in aa) == 20);
	assert(aa["twenty"] == 20);
	
	assert(aa.get("fourty", () => 40) == 40);
	assert(aa.require("twenty", () => 21) == 20);
	aa.update(
		key: "fifty",
		create: () => 50,
		update: (int _) => 51,
	);
	assert(aa["fifty"] == 50);
	int fiftyOne;
	aa.update(
		key: "fifty",
		create: () => 50,
		update: (ref int i){ i = 51; fiftyOne = i; },
	);
	assert(aa["fifty"] == 51);
	assert(fiftyOne == 51);
	{
		auto aaCmp = makeAA(gcAlloc, gcAlloc, cAlloc, "twenty",20, "fifty",51);
		scope(exit) aaCmp.dispose(gcAlloc);
		assert(aa == aaCmp);
	}
	aa.remove("fifty");
	assert("fifty" !in aa);
	
	auto keyArray = aa.getKeys(gcAlloc);
	assert(keyArray == ["twenty"]);
	gcAlloc.dispose(keyArray);
	
	auto valueArray = aa.getValues(gcAlloc);
	assert(valueArray == [20]);
	gcAlloc.dispose(valueArray);
	
	foreach(key; aa.byKey){
		assert(key == "twenty");
	}
	foreach(value; aa.byValue){
		assert(value == 20);
	}
	foreach(item; aa.byKeyValue){
		assert(item.key == "twenty");
		assert(item.value == 20);
	}
	
	import std.conv: to;
	foreach(i; 0..10)
		aa[i.to!string()] = i;
	{
		auto aaCmp = makeAA(cAlloc, gcAlloc, gcAlloc, "twenty",20, "0",0, "1",1, "2",2, "3",3, "4",4, "5",5, "6",6, "7",7, "8",8, "9",9);
		scope(exit) aaCmp.dispose(cAlloc);
		assert(aa == aaCmp);
	}
	
	foreach(i; 10..1_000)
		aa[i.to!string()] = i;
	foreach(i; 0..1_000){
		assert(i.to!string() in aa);
		assert(aa[i.to!string()] == i);
	}
	foreach(i; 0..1_000)
		aa.remove(i.to!string());
	foreach(i; 0..1_000)
		assert(i.to!string() !in aa);
	
	aa.dispose(gcAlloc);
}

private size_t nextPow2(const size_t n) nothrow @nogc pure @safe{
	if(n){
		const isPowerOf2 = !((n - 1) & n);
		import core.bitop: bsr;
		return 1 << (bsr(n) + !isPowerOf2);
	}else return 1;
}

nothrow @nogc pure @safe unittest{
	//                      0, 1, 2, 3, 4, 5, 6, 7, 8,  9
	foreach(const n, pow2; [1, 1, 2, 4, 4, 8, 8, 8, 8, 16])
		assert(nextPow2(n) == pow2);
}
