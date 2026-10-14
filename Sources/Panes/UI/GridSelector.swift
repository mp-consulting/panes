import PanesCore
import SwiftUI

/// A grid you drag across to pick an area, as in Divvy. The selection is a Liquid Glass slab that
/// follows the pointer; `committed` (if any) is shown while nothing is being dragged. Escape
/// during a drag cancels it: releasing the mouse then commits nothing, and `onCancel` is called.
struct GridSelector: View {
    let columns: Int
    let rows: Int
    var committed: GridSelection?
    var tint: Color = .accentColor
    /// Called with the selection as it changes during a drag, then `nil` when the drag ends.
    var onPreview: ((GridSelection?) -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: (GridSelection) -> Void

    @State private var dragging: GridSelection?
    @State private var hovered: Cell?
    /// Set by Escape mid-drag, so the rest of that drag is ignored.
    @State private var cancelled = false
    @State private var escapeWatcher = EscapeWatcher()

    private let gap: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                // A solid-ish bed under the cells: on glass, faint cells vanish into busy wallpapers.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.opacity(0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    }
                    .padding(-gap)

                ForEach(0..<(columns * rows), id: \.self) { index in
                    let cell = Cell(column: index % columns, row: index / columns)
                    let rect = cellRect(cell, in: size)
                    let isHovered = cell == hovered && dragging == nil
                    RoundedRectangle(cornerRadius: cornerRadius(for: rect), style: .continuous)
                        .fill(isHovered ? AnyShapeStyle(tint.opacity(0.35)) : AnyShapeStyle(.primary.opacity(0.10)))
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius(for: rect), style: .continuous)
                                .strokeBorder(.primary.opacity(isHovered ? 0.0 : 0.16), lineWidth: 1)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }

                if let shown = dragging ?? committed, shown.columns == columns, shown.rows == rows {
                    let rect = shown.frame(in: CGRect(origin: .zero, size: size)).insetBy(dx: gap / 2, dy: gap / 2)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.55))
                        .glassEffect(.regular.tint(tint.opacity(0.6)), in: .rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.55), lineWidth: 1.5)
                        }
                        .overlay {
                            Text("\(shown.maxColumn - shown.minColumn + 1)×\(shown.maxRow - shown.minRow + 1)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 2)
                                .opacity(rect.width > 44 && rect.height > 24 ? 1 : 0)
                        }
                        .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(.snappy(duration: 0.16), value: shown)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !cancelled else { return }
                        if dragging == nil { escapeWatcher.start(cancelDrag) }
                        let selection = GridSelection(
                            columns: columns, rows: rows,
                            start: cell(at: value.startLocation, in: size),
                            end: cell(at: value.location, in: size)
                        )
                        if selection != dragging { onPreview?(selection) }
                        dragging = selection
                    }
                    .onEnded { _ in
                        escapeWatcher.stop()
                        if !cancelled {
                            onPreview?(nil)
                            if let selection = dragging { onCommit(selection) }
                        }
                        dragging = nil
                        cancelled = false
                    }
            )
            .onDisappear { escapeWatcher.stop() }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location): hovered = cell(at: location, in: size)
                case .ended: hovered = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Grid of \(columns) columns and \(rows) rows; drag to select an area")
    }

    private func cancelDrag() {
        cancelled = true
        dragging = nil
        onPreview?(nil)
        onCancel?()
    }

    private func cellRect(_ cell: Cell, in size: CGSize) -> CGRect {
        GridSelection(columns: columns, rows: rows, start: cell, end: cell)
            .frame(in: CGRect(origin: .zero, size: size))
            .insetBy(dx: gap / 2, dy: gap / 2)
    }

    private func cornerRadius(for rect: CGRect) -> CGFloat {
        min(6, min(rect.width, rect.height) / 3)
    }

    private func cell(at point: CGPoint, in size: CGSize) -> Cell {
        let column = Int(point.x / size.width * CGFloat(columns))
        let row = Int(point.y / size.height * CGFloat(rows))
        return Cell(column: min(max(column, 0), columns - 1), row: min(max(row, 0), rows - 1))
    }
}

/// A non-interactive miniature of a preset's area, for lists and buttons.
struct GridThumbnail: View {
    let area: GridSelection
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: bounds, cornerRadius: 3), with: .color(.primary.opacity(0.12)))
            let rect = area.frame(in: bounds.insetBy(dx: 1.5, dy: 1.5))
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint))
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
