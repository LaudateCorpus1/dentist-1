/**
    This is the `mergeInsertions` command of `dentist`.

    Copyright: © 2018 Arne Ludwig <arne.ludwig@posteo.de>
    License: Subject to the terms of the MIT license, as written in the
             included LICENSE file.
    Authors: Arne Ludwig <arne.ludwig@posteo.de>
*/
module dentist.commands.mergeInsertions;

import dentist.common.binio : InsertionDb;
import dentist.common.insertions : Insertion;
import std.algorithm :
    isSorted,
    map,
    sort;
import std.array : array;


/// Execute the `mergeInsertions` command with `options`.
void execute(Options)(in Options options)
{
    auto mergedInsertions = options
        .insertionsFiles
        .map!readFromFile
        .map!ensureSorted
        .array
        .mergeAll;

    InsertionDb.write(options.mergedInsertionsFile, mergedInsertions);
}

Insertion[] readFromFile(in string fileName)
{
    auto insertionDb = InsertionDb.parse(fileName);

    return insertionDb[];
}

Insertion[] ensureSorted(Insertion[] insertions)
{
    if (!insertions.isSorted)
        insertions.sort;

    return insertions;
}

private auto mergeAll(T)(T[][] insertionsList)
{
    return InsertionsMerger!T(insertionsList);
}

unittest
{
    import std.algorithm.comparison : equal;
    import std.range : retro;

    int[] a = [1, 3, 5];
    int[] b = [2, 3, 4];
    int[] c = [3, 5, 6];

    assert(mergeAll([a, b, c]).equal([1, 2, 3, 3, 3, 4, 5, 5, 6]));
}

        import std.conv;
import std.stdio;

private struct InsertionsMerger(T)
{
    public T[][] sources;
    private size_t _lastFrontIndex = size_t.max;

    this(T[][] sources)
    {
        this.sources = sources;
        this._lastFrontIndex = frontIndex;
    }

    this(this)
    {
        this.sources = this.sources.dup;
    }

    @property bool empty() const pure nothrow
    {
        return _lastFrontIndex == size_t.max;
    }

    @property auto ref front() pure nothrow
    {
        debug assert(sources[_lastFrontIndex].length > 0);

        return sources[_lastFrontIndex][0];
    }

    private size_t frontIndex() pure nothrow
    {
        size_t bestIndex = size_t.max; // indicate undefined
        T bestElement;
        foreach (i, source; sources)
        {
            if (source.length == 0) continue;
            if (bestIndex == size_t.max || // either this is the first or
                source[0] < bestElement)
            {
                bestIndex = i;
                bestElement = source[0];
            }
        }
        assert(bestIndex == size_t.max || sources[bestIndex].length > 0);

        return bestIndex;
    }

    void popFront() pure nothrow
    {
        sources[_lastFrontIndex] = sources[_lastFrontIndex][1 .. $];
        _lastFrontIndex = frontIndex;
    }

    @property auto save() pure nothrow
    {
        return this;
    }

    @property size_t length() const pure nothrow
    {
        size_t result;
        foreach (source; sources)
            result += source.length;

        return result;
    }

    alias opDollar = length;
}
