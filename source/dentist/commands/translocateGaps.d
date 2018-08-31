/**
    This is the `translocateGaps` command of `dentist`.

    Copyright: © 2018 Arne Ludwig <arne.ludwig@posteo.de>
    License: Subject to the terms of the MIT license, as written in the
             included LICENSE file.
    Authors: Arne Ludwig <arne.ludwig@posteo.de>
*/
module dentist.commands.translocateGaps;

version (Testing):

import dentist.commandline : TestingCommand, OptionsFor;
import dentist.common :
    ReferenceInterval,
    ReferenceRegion,
    to;
import dentist.common.alignments :
    AlignmentChain,
    id_t;
import dentist.dazzler :
    getAlignments,
    getNumContigs,
    getFastaSequence,
    writeMask;
import dentist.util.log;
import dentist.util.range : wrapLines;
import std.algorithm :
    cache,
    copy,
    filter,
    joiner,
    map;
import std.array : array;
import std.format : format;
import std.range :
    assumeSorted,
    chain,
    chunks,
    enumerate,
    iota,
    only,
    repeat,
    slide,
    takeExactly;
import std.stdio : File, stdout;
import std.typecons : No;
import vibe.data.json : toJson = serializeToJson;


/// Options for the `collectPileUps` command.
alias Options = OptionsFor!(TestingCommand.translocateGaps);

/// Execute the `translocateGaps` command with `options`.
void execute(in Options options)
{
    auto translocator = Translocator(options);

    return translocator.run();
}

private struct Translocator
{
    alias FastaWriter = typeof(wrapLines(stdout.lockingTextWriter, 0));

    const(Options) options;
    size_t numContigsAssembly2;
    AlignmentChain[] alignments;
    ReferenceRegion mappedRegions;
    File assemblyFile;
    FastaWriter writer;

    this(in Options options)
    {
        this.options = options;
        this.assemblyFile = options.assemblyFile is null
            ? stdout
            : File(options.assemblyFile, "w");
        this.writer = wrapLines(assemblyFile.lockingTextWriter, options.fastaLineWidth);
    }

    void run()
    {
        mixin(traceExecution);

        init();
        writeOutputAssembly();
    }

    protected void init()
    {
        mixin(traceExecution);

        alignments = getAlignments(
            options.refDb,
            options.shortReadAssemblyDb,
            options.shortReadAssemblyAlignmentFile,
            options.workdir,
        );
        mappedRegions = ReferenceRegion(alignments
            .filter!"a.isProper"
            .map!(to!(ReferenceRegion, "contigA"))
            .map!"a.intervals.dup"
            .joiner
            .array);

        if (options.mappedRegionsMask !is null)
            writeMask(
                options.refDb,
                options.mappedRegionsMask,
                mappedRegions.intervals,
                options.workdir,
            );
    }

    protected void writeOutputAssembly()
    {
        mixin(traceExecution);

        immutable dchar unknownBase = 'n';
        auto numRefContigs = getNumContigs(options.refDb, options.workdir);
        auto mappedRegions = mappedRegions.intervals.assumeSorted!"a.contigId < b.contigId";
        ReferenceInterval needle;

        foreach (id_t contigId; 1 .. numRefContigs + 1)
        {
            getScaffoldHeader(contigId).copy(writer);

            auto contigSequence = getFastaSequence(
                options.refDb,
                contigId,
                options.workdir,
            );
            needle.contigId = contigId;
            auto contigMappedRegions = chain(
                only(needle),
                mappedRegions.equalRange(needle)
            );

            foreach (keepRegions; contigMappedRegions.slide!(No.withPartial)(2))
            {
                if (keepRegions[0].end > 0)
                    repeat(unknownBase)
                        .takeExactly(keepRegions[1].begin - keepRegions[0].end)
                        .copy(writer);

                contigSequence[keepRegions[1].begin .. keepRegions[1].end].copy(writer);
            }
        }

        "\n".copy(writer);
    }

    static protected string getScaffoldHeader(in size_t scaffoldId)
    {
        return format!">translocated_gaps_%d\n"(scaffoldId);
    }
}
