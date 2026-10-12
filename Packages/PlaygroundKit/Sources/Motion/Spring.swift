import PlaygroundCore

/// A 1-D damped spring integrated with semi-implicit Euler at a fixed step.
/// Fixed steps make the result independent of render frame rate, so preview == export.
public struct Spring1D: Sendable {
    public var position: Double
    public var velocity: Double = 0
    public var config: SpringConfig

    public init(position: Double, config: SpringConfig) {
        self.position = position
        self.config = config
    }

    public mutating func step(target: Double, dt: Double) {
        let force = -config.stiffness * (position - target) - config.damping * velocity
        velocity += force / config.mass * dt
        position += velocity * dt
    }

    public mutating func snap(to target: Double) {
        position = target
        velocity = 0
    }
}

/// A 2-D spring (independent axes sharing one config).
public struct Spring2D: Sendable {
    public var x: Spring1D
    public var y: Spring1D

    public init(position: NormPoint, config: SpringConfig) {
        x = Spring1D(position: position.x, config: config)
        y = Spring1D(position: position.y, config: config)
    }

    public var position: NormPoint { NormPoint(x.position, y.position) }
    public var velocity: NormPoint { NormPoint(x.velocity, y.velocity) }

    public var config: SpringConfig {
        get { x.config }
        set { x.config = newValue; y.config = newValue }
    }

    public mutating func step(target: NormPoint, dt: Double) {
        x.step(target: target.x, dt: dt)
        y.step(target: target.y, dt: dt)
    }

    public mutating func snap(to p: NormPoint) {
        x.snap(to: p.x)
        y.snap(to: p.y)
    }
}
