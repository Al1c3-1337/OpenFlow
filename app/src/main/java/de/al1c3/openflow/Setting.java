package de.al1c3.openflow;

/**
 * Setting indices written to the Settings characteristic.
 * Wire encoding (see {@link StimDevice#writeSetting}): byte[0] = ordinal of this enum,
 * byte[1..4] = little-endian IEEE-754 float. This matches the companion app, which casts the enum
 * directly to a byte -- so the ordinal IS the protocol code, and declaration order must not change.
 * Several of these toggle hardware/firmware safety interlocks. Their effect is noted inline so that
 * writing one is never an accident about what it does.
 */
@SuppressWarnings("unused")
public enum Setting {
    UserDetectedThresholdResistance,
    CurrentRampUpRate,
    CurrentRampDownRate,
    CurrentQuickRampDown,
    TargetCurrent,                          // the current setpoint delivered to the user
    MinTicketTime,
    Timeout,
    BatteryLowerProtectionLimit,            // battery cut-off threshold
    AllowStimulationDuringChargerConnected, // permits stimulation while the charger is attached
    ButtonHasBeenPressed,
    ForceLedOn,
    AssertFileNameFirst4Char,
    AssertLineNumber,
    AssertErrorCode,
    SkipElectrodeDetection,                 // bypasses the electrode-contact check before current flows
    OverResistanceThresholdVoltageOnPadA,   // compliance-voltage limit on pad A
    FaultThresholdVoltageOnPadA,            // fault-voltage limit on pad A
    DisableTickets,                         // removes the ticket authorisation/usage gate
    MaxStimulationTime,                     // hard upper bound on stimulation duration
    DisconnectFromPhone;

    /** Protocol code = ordinal, matching the companion app's (byte) cast. */
    public byte code() {
        return (byte) ordinal();
    }
}
