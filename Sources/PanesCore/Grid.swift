import CoreGraphics

/// A cell position on a grid. Row 0 is the top row, column 0 the left column.
public struct Cell: Codable, Equatable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// A rectangular selection of cells on a `columns` x `rows` grid, inclusive on both ends.
/// The two corners may be given in any order (a drag can go up-left).
public struct GridSelection: Codable, Equatable, Sendable {
    /// The finest grid a decoded selection keeps: twice the largest grid, as a subdivided Divvy grid has.
    public static let maxSize = 48

    public var columns: Int
    public var rows: Int
    public var start: Cell
    public var end: Cell

    public init(columns: Int, rows: Int, start: Cell, end: Cell) {
        self.columns = columns
        self.rows = rows
        self.start = start
        self.end = end
    }

    // A hand-edited size of 0 would divide by zero, and a huge one would stall the views drawing it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            columns: max(try c.decode(Int.self, forKey: .columns), 1),
            rows: max(try c.decode(Int.self, forKey: .rows), 1),
            start: try c.decode(Cell.self, forKey: .start),
            end: try c.decode(Cell.self, forKey: .end)
        )
        if columns > Self.maxSize || rows > Self.maxSize {
            self = resized(columns: min(columns, Self.maxSize), rows: min(rows, Self.maxSize))
        }
    }

    public var isValid: Bool {
        columns > 0 && rows > 0
            && (0..<columns).contains(start.column) && (0..<columns).contains(end.column)
            && (0..<rows).contains(start.row) && (0..<rows).contains(end.row)
    }

    public var minColumn: Int { min(start.column, end.column) }
    public var maxColumn: Int { max(start.column, end.column) }
    public var minRow: Int { min(start.row, end.row) }
    public var maxRow: Int { max(start.row, end.row) }

    /// The selection's frame inside `area`, in a top-left-origin coordinate space
    /// (the Accessibility API's). Edges are rounded so adjacent selections tile without gaps.
    public func frame(in area: CGRect) -> CGRect {
        let x0 = edge(area.minX, area.width, minColumn, columns)
        let x1 = edge(area.minX, area.width, maxColumn + 1, columns)
        let y0 = edge(area.minY, area.height, minRow, rows)
        let y1 = edge(area.minY, area.height, maxRow + 1, rows)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The same area of the screen, approximated on a `columns` x `rows` grid.
    public func resized(columns newColumns: Int, rows newRows: Int) -> GridSelection {
        func scale(_ lo: Int, _ hi: Int, from old: Int, to new: Int) -> (Int, Int) {
            let first = Int((Double(lo) * Double(new) / Double(old)).rounded())
            let last = Int((Double(hi + 1) * Double(new) / Double(old)).rounded()) - 1
            let clampedFirst = min(max(first, 0), new - 1)
            return (clampedFirst, min(max(last, clampedFirst), new - 1))
        }
        let (c0, c1) = scale(minColumn, maxColumn, from: columns, to: newColumns)
        let (r0, r1) = scale(minRow, maxRow, from: rows, to: newRows)
        return GridSelection(columns: newColumns, rows: newRows, start: Cell(column: c0, row: r0), end: Cell(column: c1, row: r1))
    }

    private func edge(_ origin: CGFloat, _ length: CGFloat, _ index: Int, _ count: Int) -> CGFloat {
        (origin + length * CGFloat(index) / CGFloat(count)).rounded()
    }
}

/// Converts between AppKit's global space (origin bottom-left of the primary screen, y up)
/// and the Accessibility/Quartz global space (origin top-left of the primary screen, y down).
public func flipped(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
}
