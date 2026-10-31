// LearningCurveSVG.swift - Generate SVG learning curve from loss history
// Copyright 2026

import Foundation

/// Generates an SVG learning curve visualization from training loss history.
///
/// Produces two lines: raw loss (light gray) and moving-average smoothed loss (blue).
/// The SVG is overwritten each step for live monitoring.
enum LearningCurveSVG {

    /// Generate an SVG learning curve and write to `outputDir/learning_curve.svg`
    static func generate(
        lossHistory: [(step: Int, loss: Float)],
        outputDir: String,
        smoothingWindow: Int = 20
    ) {
        guard lossHistory.count >= 2 else { return }

        let svgPath = (outputDir as NSString).appendingPathComponent("learning_curve.svg")

        // SVG dimensions
        let width: Float = 800
        let height: Float = 400
        let padding: Float = 60
        let plotWidth = width - 2 * padding
        let plotHeight = height - 2 * padding

        // Compute smoothed loss using moving average
        let windowSize = min(smoothingWindow, lossHistory.count)
        var smoothedLoss: [(step: Int, loss: Float)] = []

        for i in 0..<lossHistory.count {
            let start = max(0, i - windowSize + 1)
            let window = lossHistory[start...i]
            let avgLoss = window.map { $0.loss }.reduce(0, +) / Float(window.count)
            smoothedLoss.append((step: lossHistory[i].step, loss: avgLoss))
        }

        // Find min/max for scaling (use raw values for full range)
        let minStep = Float(lossHistory.first!.step)
        let maxStep = Float(lossHistory.last!.step)
        let stepRange = max(maxStep - minStep, 1)

        let rawLosses = lossHistory.map { $0.loss }
        let minLoss = rawLosses.min() ?? 0
        let maxLoss = rawLosses.max() ?? 1
        let lossRange = max(maxLoss - minLoss, 0.001)

        // Add 10% padding to loss range
        let paddedMinLoss = minLoss - lossRange * 0.1
        let paddedMaxLoss = maxLoss + lossRange * 0.1
        let paddedLossRange = paddedMaxLoss - paddedMinLoss

        // Helper to convert data to SVG coordinates
        func toSVG(step: Int, loss: Float) -> (x: Float, y: Float) {
            let x = padding + (Float(step) - minStep) / stepRange * plotWidth
            let y = padding + (1 - (loss - paddedMinLoss) / paddedLossRange) * plotHeight
            return (x, y)
        }

        // Build SVG path for smoothed curve
        var pathData = ""
        for (i, point) in smoothedLoss.enumerated() {
            let (x, y) = toSVG(step: point.step, loss: point.loss)
            if i == 0 {
                pathData += "M \(x) \(y)"
            } else {
                pathData += " L \(x) \(y)"
            }
        }

        // Build raw data line (lighter)
        var rawPathData = ""
        for (i, point) in lossHistory.enumerated() {
            let (x, y) = toSVG(step: point.step, loss: point.loss)
            if i == 0 {
                rawPathData += "M \(x) \(y)"
            } else {
                rawPathData += " L \(x) \(y)"
            }
        }

        // Generate axis labels
        let stepLabels = axisLabels(min: minStep, max: maxStep, count: 5)
        let lossLabels = axisLabels(min: paddedMinLoss, max: paddedMaxLoss, count: 5)

        // Build SVG
        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)" width="\(Int(width))" height="\(Int(height))">
          <style>
            .title { font: bold 16px sans-serif; }
            .label { font: 12px sans-serif; }
            .axis-label { font: 10px sans-serif; fill: #666; }
            .grid { stroke: #e0e0e0; stroke-width: 1; }
            .raw-line { fill: none; stroke: #ccc; stroke-width: 1; }
            .smooth-line { fill: none; stroke: #2196F3; stroke-width: 2; }
            .current-loss { font: bold 14px sans-serif; fill: #2196F3; }
          </style>
          <rect width="\(width)" height="\(height)" fill="white"/>
          <text x="\(width/2)" y="25" text-anchor="middle" class="title">Learning Curve</text>
        """

        // Horizontal grid lines (loss)
        for label in lossLabels {
            let (_, y) = toSVG(step: Int(minStep), loss: label)
            svg += """
              <line x1="\(padding)" y1="\(y)" x2="\(width - padding)" y2="\(y)" class="grid"/>
              <text x="\(padding - 5)" y="\(y + 4)" text-anchor="end" class="axis-label">\(String(format: "%.4f", label))</text>
            """
        }

        // Vertical grid lines (step)
        for label in stepLabels {
            let (x, _) = toSVG(step: Int(label), loss: paddedMinLoss)
            svg += """
              <line x1="\(x)" y1="\(padding)" x2="\(x)" y2="\(height - padding)" class="grid"/>
              <text x="\(x)" y="\(height - padding + 15)" text-anchor="middle" class="axis-label">\(Int(label))</text>
            """
        }

        // Axis labels
        svg += """
          <text x="\(width/2)" y="\(height - 10)" text-anchor="middle" class="label">Step</text>
          <text x="15" y="\(height/2)" text-anchor="middle" class="label" transform="rotate(-90, 15, \(height/2))">Loss</text>
        """

        // Raw data line (light gray)
        svg += "  <path d=\"\(rawPathData)\" class=\"raw-line\"/>\n"

        // Smoothed line (blue)
        svg += "  <path d=\"\(pathData)\" class=\"smooth-line\"/>\n"

        // Current loss indicator
        if let last = smoothedLoss.last {
            let (x, y) = toSVG(step: last.step, loss: last.loss)
            svg += """
              <circle cx="\(x)" cy="\(y)" r="4" fill="#2196F3"/>
              <text x="\(x + 10)" y="\(y + 5)" class="current-loss">\(String(format: "%.4f", last.loss))</text>
            """
        }

        // Stats box
        let currentLoss = lossHistory.last?.loss ?? 0
        let avgLoss = smoothedLoss.last?.loss ?? 0
        svg += """
          <rect x="\(width - 150)" y="40" width="140" height="60" fill="white" stroke="#ddd" rx="4"/>
          <text x="\(width - 145)" y="58" class="axis-label">Step: \(lossHistory.last?.step ?? 0)</text>
          <text x="\(width - 145)" y="73" class="axis-label">Loss: \(String(format: "%.4f", currentLoss))</text>
          <text x="\(width - 145)" y="88" class="axis-label">Smoothed: \(String(format: "%.4f", avgLoss))</text>
        </svg>
        """

        do {
            try svg.write(toFile: svgPath, atomically: true, encoding: .utf8)
        } catch {
            LTXDebug.log("[LearningCurve] Failed to write SVG: \(error)")
        }
    }

    /// Generate evenly spaced axis labels
    private static func axisLabels(min: Float, max: Float, count: Int) -> [Float] {
        guard count > 1 else { return [min] }
        let step = (max - min) / Float(count - 1)
        return (0..<count).map { min + Float($0) * step }
    }
}
