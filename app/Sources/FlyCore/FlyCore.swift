import CoreGraphics

/// What the fly senses this frame. Built by FlyBehavior, consumed by a `Brain`.
/// Coordinates are AppKit global screen points (origin bottom-left, y up).
public struct Percept: Sendable {
    public var flyPosition: CGPoint
    /// Radians, 0 = +x, counter-clockwise positive.
    public var flyHeading: Double
    public var airborne: Bool
    public var pointer: CGPoint
    /// Pointer velocity in points/second.
    public var pointerVelocity: CGVector
    /// Distance in points from the fly to each perch surface.
    public var distanceToLeftEdge: Double
    public var distanceToRightEdge: Double
    public var distanceToBottom: Double
    /// Seconds since the last threat or takeoff.
    public var idleTime: Double
    public var screenSize: CGSize
    /// Time-to-contact (s) with the screen border ahead in the left / right visual hemifield
    /// (distance along the gaze ray ÷ closing speed); +infinity when not closing. Airborne only.
    public var edgeTimeToContactLeft: Double = .infinity
    public var edgeTimeToContactRight: Double = .infinity
    /// Speed (pt/s) at which the fly closes on the nearest border along its heading (0 when receding).
    public var edgeClosingSpeed: Double = 0
    /// v3: distance (pt) along the left / right gaze ray to the visual border (+infinity when grounded).
    public var edgeDistanceLeft: Double = .infinity
    public var edgeDistanceRight: Double = .infinity
    /// v3 perch seeking: the perch target FlyBehavior picked after a flight bout (airborne only).
    /// Bearing in radians relative to the heading (positive = target on the left), distance in points
    /// (+infinity = no target), time-to-contact = distance ÷ closing speed (+infinity when not closing).
    public var targetBearing: Double = 0
    public var targetDistance: Double = .infinity
    public var targetTimeToContact: Double = .infinity
    /// The left / right gaze ray ends on the target perch's border (the encoder does not steer away from it).
    public var edgeIsTargetLeft: Bool = false
    public var edgeIsTargetRight: Bool = false
    /// v4 flocking (boids), airborne only; all 0 when alone or perched. Bearings are relative to the heading
    /// (positive = left). `flockBearing`/`flockStrength` (0...1) is the combined alignment + cohesion pull,
    /// `separationBearing`/`separationStrength` (0...1) points AWAY from too-close neighbours,
    /// `flockSpeedRatio` = neighbours' weighted mean speed ÷ own speed (1 = matched, 0 = no neighbours).
    /// These are encoder inputs onto steering/thrust only; they must never drive the loom (escape) groups.
    public var flockBearing: Double = 0
    public var flockStrength: Double = 0
    public var separationBearing: Double = 0
    public var separationStrength: Double = 0
    public var flockSpeedRatio: Double = 0
    /// v4 (module L): social takeoff, perched only: 0...1 when the flock leader has just taken off nearby.
    /// Encoded like restlessness onto the voluntary-takeoff (non-giant-fiber) escape DNs, never onto loom.
    public var flockTakeoffDrive: Double = 0
    /// v5: the surface the fly stands on (a window) just moved / resized / closed: 0...1, decays over ~0.3 s.
    /// Encoded onto mechano + voluntary-takeoff (escape_dn minus gf) — a substrate-vibration startle.
    public var substrateJolt: Double = 0
    /// v5: a nearby window (within ~150 pt) moved: weaker visual-motion startle 0...1, decays over ~0.3 s.
    public var windowMotionStartle: Double = 0
    /// v5 (module Q): bearing (rad, relative to the heading, + = left) of the nearest point of the window whose
    /// motion drives `windowMotionStartle` (the encoder turns away from it while airborne).
    public var windowMotionBearing: Double = 0

    public init(flyPosition: CGPoint = .zero, flyHeading: Double = 0, airborne: Bool = false,
                pointer: CGPoint = .zero, pointerVelocity: CGVector = .zero,
                distanceToLeftEdge: Double = 0, distanceToRightEdge: Double = 0, distanceToBottom: Double = 0,
                idleTime: Double = 0, screenSize: CGSize = CGSize(width: 1440, height: 900)) {
        self.flyPosition = flyPosition; self.flyHeading = flyHeading; self.airborne = airborne
        self.pointer = pointer; self.pointerVelocity = pointerVelocity
        self.distanceToLeftEdge = distanceToLeftEdge; self.distanceToRightEdge = distanceToRightEdge
        self.distanceToBottom = distanceToBottom; self.idleTime = idleTime; self.screenSize = screenSize
    }
}

/// Behavioural drive decoded from descending/motor neuron activity. All 0...1 except `yawRate`.
public struct MotorCommand: Sendable, Equatable {
    public var takeoff: Double
    public var thrust: Double
    /// rad/s, positive = turn left (counter-clockwise).
    public var yawRate: Double
    public var land: Double
    public var walkSpeed: Double
    public var backward: Double
    public var freeze: Double
    public var groom: Double

    public init(takeoff: Double = 0, thrust: Double = 0, yawRate: Double = 0, land: Double = 0,
                walkSpeed: Double = 0, backward: Double = 0, freeze: Double = 0, groom: Double = 0) {
        self.takeoff = takeoff; self.thrust = thrust; self.yawRate = yawRate; self.land = land
        self.walkSpeed = walkSpeed; self.backward = backward; self.freeze = freeze; self.groom = groom
    }
    public static let idle = MotorCommand()
}

public protocol Brain: AnyObject {
    func step(_ percept: Percept, dt: Double) -> MotorCommand
    /// Named activity levels (e.g. "GF", "escape", "landing") for the optional brain overlay.
    var activity: [String: Float] { get }
}

public enum FlyState: String, Sendable, CaseIterable {
    case perched, walking, grooming, takingOff, flying, escaping, landing
}

public enum Perch: String, Sendable {
    case left, right, bottom
}

/// Animation parameters handed from FlyBehavior to FlyBody.
public struct BodyPose: Sendable, Equatable {
    /// 0 = wings folded over abdomen, 1 = full flight stroke.
    public var wingStroke: Double
    /// Wing-beat phase in radians (advanced by FlyBehavior).
    public var wingPhase: Double
    /// Tripod gait phase in radians and blend 0...1.
    public var walkPhase: Double
    public var walkAmount: Double
    /// Grooming leg-sweep phase in radians and blend 0...1.
    public var groomPhase: Double
    public var groomAmount: Double
    /// Legs tucked for flight, 0...1.
    public var legTuck: Double
    public var headYaw: Double

    public init(wingStroke: Double = 0, wingPhase: Double = 0, walkPhase: Double = 0, walkAmount: Double = 0,
                groomPhase: Double = 0, groomAmount: Double = 0, legTuck: Double = 0, headYaw: Double = 0) {
        self.wingStroke = wingStroke; self.wingPhase = wingPhase; self.walkPhase = walkPhase
        self.walkAmount = walkAmount; self.groomPhase = groomPhase; self.groomAmount = groomAmount
        self.legTuck = legTuck; self.headYaw = headYaw
    }
    public static let rest = BodyPose()
}

/// Per-frame output of FlyBehavior, consumed by the renderer.
public struct FlyFrame: Sendable {
    public var position: CGPoint
    /// Heading in the screen plane (radians, 0 = +x).
    public var heading: Double
    /// 1 = on a surface, >1 = closer to viewer while flying (visual scale).
    public var altitudeScale: Double
    public var state: FlyState
    public var perch: Perch?
    public var pose: BodyPose
    /// Body roll about its long axis (radians, positive = right side down). Banking in turns, and the
    /// three-quarter tilt when perched on a vertical edge.
    public var roll: Double = 0
    /// Body pitch (radians, positive = nose up). Takeoff / landing / climb.
    public var pitch: Double = 0

    public init(position: CGPoint, heading: Double, altitudeScale: Double = 1, state: FlyState,
                perch: Perch? = nil, pose: BodyPose = .rest, roll: Double = 0, pitch: Double = 0) {
        self.position = position; self.heading = heading; self.altitudeScale = altitudeScale
        self.state = state; self.perch = perch; self.pose = pose; self.roll = roll; self.pitch = pitch
    }
}

/// User settings shown in the menu-bar menu and persisted in UserDefaults (suite = bundle id).
public struct DeweySettings: Codable, Sendable, Equatable {
    /// Fly body length on screen, points (20...120).
    public var size: Double = 40
    /// 0 = calm (long perched bouts), 1 = restless (short bouts).
    public var restlessness: Double = 0.5
    /// false = fly hidden (simulation paused).
    public var visible: Bool = true
    /// v4: number of companion flies (0...5).
    public var friends: Int = 0

    public init(size: Double = 40, restlessness: Double = 0.5, visible: Bool = true, friends: Int = 0) {
        self.size = size; self.restlessness = restlessness; self.visible = visible; self.friends = friends
    }
    public static let sizeRange: ClosedRange<Double> = 20...120
    public static let friendsRange: ClosedRange<Int> = 0...5
    /// Friends are this fraction of Dewey's size (drawn once per friend).
    public static let friendSizeFactor: ClosedRange<Double> = 0.85...0.90

    private enum CodingKeys: String, CodingKey { case size, restlessness, visible, friends }
    /// Tolerant decode: missing keys keep their defaults instead of failing the whole value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeweySettings()
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        restlessness = try c.decodeIfPresent(Double.self, forKey: .restlessness) ?? d.restlessness
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        friends = try c.decodeIfPresent(Int.self, forKey: .friends) ?? d.friends
    }

    /// Perched-bout length range (s) for the restlessness drive: calm 60-180 s, restless 8-25 s.
    /// (v5: shifted toward perching at both ends — calm is calmer, restless less active.)
    public var restBout: ClosedRange<Double> {
        let r = min(max(restlessness, 0), 1)
        let lo = 60 + (8 - 60) * r, hi = 180 + (25 - 180) * r
        return lo...hi
    }

    /// Flight-bout length range (s) before the fly picks a perch target: calm 5-12 s, restless 6-16 s
    /// (v5: short flights at both ends, so the fly spends most of its time perched).
    public var flightBout: ClosedRange<Double> {
        let r = min(max(restlessness, 0), 1)
        let lo = 5 + (6 - 5) * r, hi = 12 + (16 - 12) * r
        return lo...hi
    }
}

/// Brains whose voluntary-takeoff (restlessness) timing can be tuned live from settings.
public protocol RestlessnessTunable: AnyObject {
    func setRestBout(_ range: ClosedRange<Double>)
}

/// What one fly sees of another for flocking (v4). Global screen points; velocity in pt/s.
public struct FlockNeighbor: Sendable, Equatable {
    public var id: Int
    public var position: CGPoint
    public var velocity: CGVector
    public var heading: Double
    public var airborne: Bool
    /// Dewey (the flock leader); friends weight the leader more in cohesion/alignment.
    public var isLeader: Bool
    /// Body length in points.
    public var size: Double
    /// Where this fly is perched (or heading to perch), if anywhere — friends bias their perch choice toward the leader's.
    public var perchPoint: CGPoint?

    public init(id: Int, position: CGPoint, velocity: CGVector = .zero, heading: Double = 0, airborne: Bool = false,
                isLeader: Bool = false, size: Double = 40, perchPoint: CGPoint? = nil) {
        self.id = id; self.position = position; self.velocity = velocity; self.heading = heading
        self.airborne = airborne; self.isLeader = isLeader; self.size = size; self.perchPoint = perchPoint
    }
}
