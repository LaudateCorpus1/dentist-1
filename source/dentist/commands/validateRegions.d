/**
    This is the `validateRegions` command of `dentist`.

    Copyright: © 2018 Arne Ludwig <arne.ludwig@posteo.de>
    License: Subject to the terms of the MIT license, as written in the
             included LICENSE file.
    Authors: Arne Ludwig <arne.ludwig@posteo.de>
*/
module dentist.commands.validateRegions;

import dentist.commandline : OptionsFor;
import dentist.commands.maskRepetitiveRegions :
    BadAlignmentCoverageAssessor;
import dentist.common :
    dentistEnforce,
    ReferenceInterval,
    ReferencePoint,
    ReferenceRegion;
import dentist.common.alignments :
    FlatLocalAlignment,
    coord_t,
    id_t,
    Locus;
import dentist.common.commands : DentistCommand;
import dentist.dazzler :
    ContigSegment,
    DazzExtraNotFound,
    getFlatLocalAlignments,
    getScaffoldStructure,
    lasEmpty,
    readDazzExtra,
    readMask,
    writeMask;
import dentist.util.algorithm : filterInPlace;
import dentist.util.log;
import dentist.util.range : arrayChunks;
import dentist.util.region : empty;
import std.algorithm :
    count,
    filter,
    isSorted,
    joiner,
    map,
    maxElement,
    min,
    sort;
import std.array :
    appender,
    array,
    uninitializedArray;
import std.conv : to;
import std.range :
    assumeSorted,
    only,
    StoppingPolicy,
    tee,
    zip;
import std.range.primitives;
import std.stdio : writeln;
import std.typecons : Tuple;
import vibe.data.json : toJson = serializeToJson;


/// Options for the `validateRegions` command.
alias Options = OptionsFor!(DentistCommand.validateRegions);


/// Execute the `validateRegions` command with `options`.
void execute(in Options options)
{
    auto validator = new RegionsValidator(options);

    validator.run();
}


bool byContigAId(const FlatLocalAlignment lhs, const FlatLocalAlignment rhs) pure nothrow @safe
{
    return lhs.contigA.id < rhs.contigA.id;
}


class RegionsValidator
{
    protected const Options options;
    protected ContigSegment[] contigs;
    protected FlatLocalAlignment[] alignments;
    protected id_t minContigAId;
    protected id_t maxContigAId;
    protected ReferenceInterval[] regions;
    protected id_t[2][] contigIds;
    protected id_t[][] readIds;
    protected ReferenceInterval[] regionsWithContext;
    protected ReferenceRegion weakCoverageMask;

    this(const Options options)
    {
        this.options = options;
    }

    void run()
    {
        mixin(traceExecution);

        readInputs();
        validateRegions();
    }

    protected void readInputs()
    {
        mixin(traceExecution);

        contigs = getScaffoldStructure(options.refDb)
            .filter!(part => part.peek!ContigSegment !is null)
            .map!(contigPart => contigPart.get!ContigSegment)
            .map!(contigPart => contigPart)
            .array;

        if (lasEmpty(options.readsAlignmentFile))
        {
            logJsonWarn(
                "info", "empty reads-alignment",
                "readsAlignmentFile", options.readsAlignmentFile,
            );

            return;
        }

        alignments = getFlatLocalAlignments(
            options.refDb,
            options.readsDb,
            options.readsAlignmentFile,
        ).array;
        dentistEnforce(
            alignments.isSorted!byContigAId,
            "reads-alignment must be sorted at least by a-read ID",
        );
        minContigAId = alignments[0].contigA.id;
        maxContigAId = alignments[$ - 1].contigA.id;

        regions = readMask!ReferenceInterval(options.refDb, options.regions);
        contigIds = readContigIdsFromTrackExtra();
        readIds = readReadIdsFromTrackExtra();

        restrictRegionsToContigBounds(regions);
        regionsWithContext = regions
            .map!(interval => ReferenceInterval(
                interval.contigId,
                interval.begin > options.regionContext
                    ? interval.begin - options.regionContext
                    : 0,
                min(
                    interval.end + options.regionContext,
                    contigLength(cast(id_t) interval.contigId),
                ),
            ))
            .tee!(interval => assert(&interval))
            .array;

        if (alignments.length == 0)
            logJsonWarn("info", "empty reads-alignment");
    }


    id_t[2][] readContigIdsFromTrackExtra()
    {
        try
        {
            auto contigsExtra = readDazzExtra!long(
                options.refDb,
                options.regions,
                Options.contigsExtraName,
            );

            return contigsExtra
                .map!(contigId => contigId.to!id_t)
                .arrayChunks(2)
                .map!(idPair => idPair.to!(id_t[2]))
                .array;
        }
        catch (DazzExtraNotFound e) {
            return [];
        }
    }


    id_t[][] readReadIdsFromTrackExtra()
    {
        try
        {
            auto readsExtra = readDazzExtra!long(
                options.refDb,
                options.regions,
                Options.readsExtraName,
            );

            auto readIdsBuffer = readsExtra
                .map!(contigId => contigId.to!id_t)
                .array;

            typeof(return) readIds;
            readIds.reserve(regions.length);
            while (readIdsBuffer.length > 0)
            {
                auto numIds = readIdsBuffer[0];
                readIdsBuffer = readIdsBuffer[1 .. $];

                readIds ~= readIdsBuffer[0 .. numIds];
                readIdsBuffer = readIdsBuffer[numIds .. $];
            }

            return readIds;
        }
        catch (DazzExtraNotFound e) {
            return [];
        }
    }


    void restrictRegionsToContigBounds(ref ReferenceInterval[] intervals)
    {
        auto lowerBoundIntervals = intervals
            .assumeSorted!"a.contigId < b.contigId"
            .lowerBound(ReferenceInterval(maxContigAId));
        intervals = lowerBoundIntervals
            .upperBound(ReferenceInterval(minContigAId))
            .release;

        auto sliceBegin = lowerBoundIntervals.length - intervals.length;
        auto sliceEnd = lowerBoundIntervals.length;

        contigIds = contigIds[sliceBegin .. sliceEnd];
        readIds = readIds[sliceBegin .. sliceEnd];
    }


    void validateRegions()
    {
        mixin(traceExecution);

        foreach (
            region, regionWithContext, regionContigs, consensusReadIds;
            zip(
                StoppingPolicy.longest,
                regions,
                regionsWithContext,
                contigIds,
                readIds,
            )
        )
        {
            auto validator = RegionValidator(
                options,
                cast(const) alignments,
                region,
                regionWithContext,
                regionContigs,
                consensusReadIds,
            );

            validator.run();

            weakCoverageMask |= validator.weakCoverageMask;
        }

        if (options.weakCoverageMask !is null)
            writeMask(options.refDb, options.weakCoverageMask, weakCoverageMask.intervals);
    }


    coord_t contigLength(id_t contigId)
    {
        auto contig = contigs[contigId - 1];

        assert(contig.globalContigId == contigId);

        return cast(coord_t) contig.length;
    }
}


struct RegionValidator
{
    protected const Options options;
    protected const(FlatLocalAlignment)[] alignments;
    protected ReferenceInterval region;
    protected ReferenceInterval regionWithContext;
    protected id_t[2] regionContigs;
    protected id_t[] consensusReadIds;

    id_t[] spanningReadIds;
    ReferenceRegion weakCoverageMask;

    this(
        const Options options,
        const FlatLocalAlignment[] alignments,
        ReferenceInterval region,
        ReferenceInterval regionWithContext,
        id_t[2] regionContigs,
        id_t[] consensusReadIds,
    )
    {
        this.options = options;
        this.alignments = alignments;
        this.region = region;
        this.regionWithContext = regionWithContext;
        this.regionContigs = regionContigs;
        this.consensusReadIds = consensusReadIds;
    }

    void run()
    {
        mixin(traceExecution);

        reduceAlignments();
        assessSpanningReadsStats();
        assessWeaklySpannedWindowStats();

        if (numSpanningReads < options.minSpanningReads || !empty(weakCoverageMask))
        {
            auto report = [
                "region": region.toJson,
                "regionWithContext": regionWithContext.toJson,
                "numSpanningReads": numSpanningReads.toJson,
                "spanningReadIds": spanningReadIds.toJson,
                "weakCoverageMaskBps": weakCoverageMask.size.toJson,
            ];

            if (regionContigs[0] > 0)
            {
                report["contigIds"] = regionContigs.toJson;
                report["consensusReadIds"] = consensusReadIds.toJson;
            }

            writeln(report.toJson);
        }
    }


    void reduceAlignments()
    {
        FlatLocalAlignment mkNeedle()
        {
            FlatLocalAlignment needle;
            needle.contigA.id = cast(id_t) region.contigId;
            // avoid validity check
            needle.flags.disabled = true;

            return needle;
        }

        alignments = alignments
            .assumeSorted!byContigAId
            .equalRange(mkNeedle())
            .release;
    }


    void assessSpanningReadsStats()
    {
        spanningReadIds.length = 0;
        spanningReadIds.reserve(10 * options.minCoverageReads);

        foreach (localAlignment; alignments)
            if (
                localAlignment.contigA.begin < regionWithContext.begin &&
                regionWithContext.end < localAlignment.contigA.end
            )
                spanningReadIds ~= localAlignment.contigB.id;
    }


    void assessWeaklySpannedWindowStats()
    {
        enum Bound : byte
        {
            close = -1,
            open = 1,
        }

        alias AlignmentBound = Tuple!(
            coord_t, "refPos",
            Bound, "bound",
            id_t, "readId",
        );

        auto alignmentBounds = alignments
            .map!(fla => only(
                AlignmentBound(fla.contigA.begin, Bound.open, fla.contigB.id),
                AlignmentBound(fla.contigA.end, Bound.close, fla.contigB.id),
            ))
            .joiner
            .array
            .sort
            .release;

        auto firstWindowBegin = cast(coord_t) regionWithContext.begin;
        auto lastWindowBegin = regionWithContext.end > regionWithContext.begin + options.weakCoverageWindow
            ? cast(coord_t) regionWithContext.end - options.weakCoverageWindow
            : cast(coord_t) regionWithContext.begin;

        auto weakCoverageMaskAcc = appender!(ReferenceInterval[]);
        coord_t[id_t] alignmentBegins;
        auto window = ReferenceInterval(region.contigId, firstWindowBegin);
        while (window.begin < lastWindowBegin && alignmentBounds.length > 0)
        {
            window.end = window.begin + options.weakCoverageWindow;

            foreach (i, alignmentBound; alignmentBounds)
            {
                if (alignmentBound.refPos < window.end)
                {
                    final switch (alignmentBound.bound)
                    {
                        case Bound.open:
                            alignmentBegins[alignmentBound.readId] = alignmentBound.refPos;
                            continue;
                        case Bound.close:
                            alignmentBegins.remove(alignmentBound.readId);
                            continue;
                    }
                }
                else
                {
                    alignmentBounds = alignmentBounds[i .. $];
                    break;
                }
            }

            auto numSpanningReads = cast(id_t) alignmentBegins
                .byValue
                .count!(openRefPos => openRefPos <= window.begin);

            if (numSpanningReads < options.minCoverageReads)
            {
                if (
                    weakCoverageMaskAcc.data.length == 0 ||
                    weakCoverageMaskAcc.data[$ - 1].end < window.begin
                )
                    weakCoverageMaskAcc ~= ReferenceInterval(
                        region.contigId,
                        window.begin,
                        window.end,
                    );
                else
                    weakCoverageMaskAcc.data[$ - 1].end = window.end;
            }

            ++window.begin;
        }

        weakCoverageMask = ReferenceRegion(weakCoverageMaskAcc.data);
    }


    @property id_t numSpanningReads() const pure nothrow @safe
    {
        return cast(id_t) spanningReadIds.length;
    }
}