package de.al1c3.openflow;

/**
 * Stimulation status codes (Status characteristic). The first twelve are sequential 0..11 in the
 * app's declaration order; Unknown is explicitly 255, so explicit codes are used rather than ordinals.
 */
public enum StimulationStatus {
    Idle(0),
    Fault(1),
    WaitForUser(2),
    UserDetected(3),
    RampUp(4),
    CurrentHold(5),
    RampDown(6),
    QuickRampDown(7),
    WaitForElectrodes(8),
    ElectrodesDetected(9),
    SelfDiagnostic(10),
    PanelSelfDiagnostic(11),
    Unknown(255);

    private final int code;

    StimulationStatus(int code) {
        this.code = code;
    }

    public byte code() {
        return (byte) code;
    }

    /** Decode a status byte; anything unrecognised maps to {@link #Unknown}. */
    public static StimulationStatus fromCode(int value) {
        int v = value & 0xFF;
        for (StimulationStatus s : values()) {
            if (s.code == v) {
                return s;
            }
        }
        return Unknown;
    }
}
