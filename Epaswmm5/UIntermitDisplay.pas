unit UIntermitDisplay;

interface

uses
  SysUtils, Classes, Uproject, Uglobals, Uutils;

const
  // Default float valve height used when a junction has none set
  // (mirrors the default placed in JunctionDefaultData in objprops.txt).
  DEFAULT_FLOAT_VALVE_HT = 0.9;

procedure BuildIntermitIDs(const JuncID: String;
  out StorageID, OutfallID, LkOutfallID, WOutletID, LOutletID, COutletID: String);

procedure BuildIntermitCurveIDs(const JuncID: String;
  out RatingCurveID, ControlCurveID: String);

function JunctionHasIntermitStorage(N: TNode): Boolean;
function JunctionIsIntermittent(N: TNode): Boolean;
function IsIntermitGeneratedID(const ID: String): Boolean;

procedure SyncIntermitObjects;

implementation

// ---------------------------------------------------------------------------
// ID builder
// Naming conventions must stay in sync with Uexport.pas and Uimport.pas:
//   Storage     : '_IS_ST_'     + JuncID  (truncated to '_IS_ST_'     + first 13 chars)
//   Outfall     : '_Outfall_'   + JuncID  (truncated to '_Outfall_'   + first 13 chars)
//   LkOutfall   : '_L_Outfall_' + JuncID  (truncated to '_L_Outfall_' + first 12 chars)
//   WOutlet     : 'W_OUTLET_'   + JuncID  (truncated to 'W_OUTLET_'   + first 13 chars)
//   LOutlet     : '_L_OUTLET_'  + JuncID  (truncated to '_L_OUTLET_'  + first 13 chars)
//   COutlet     : '_C_OUTLET_'  + JuncID  (truncated to '_C_OUTLET_'  + first 13 chars)
// This function is the single source of truth for these names: it is used
// both by SyncIntermitObjects (which materializes the real objects) and by
// the handful of Uexport.pas routines (rating curve, control curve/rule)
// that still refer to these objects by name.
// ---------------------------------------------------------------------------
procedure BuildIntermitIDs(const JuncID: String;
  out StorageID, OutfallID, LkOutfallID, WOutletID, LOutletID, COutletID: String);
begin
  StorageID   := '_IS_ST_'     + JuncID;
  OutfallID   := '_Outfall_'   + JuncID;
  LkOutfallID := '_L_Outfall_' + JuncID;
  WOutletID   := 'W_OUTLET_'   + JuncID;
  LOutletID   := '_L_OUTLET_'  + JuncID;
  COutletID   := '_C_OUTLET_'  + JuncID;

  if Length(StorageID)   > 16 then StorageID   := '_IS_ST_'     + Copy(JuncID, 1, 13);
  if Length(OutfallID)   > 16 then OutfallID   := '_Outfall_'   + Copy(JuncID, 1, 13);
  if Length(LkOutfallID) > 16 then LkOutfallID := '_L_Outfall_' + Copy(JuncID, 1, 12);
  if Length(WOutletID)   > 16 then WOutletID   := 'W_OUTLET_'   + Copy(JuncID, 1, 13);
  if Length(LOutletID)   > 16 then LOutletID   := '_L_OUTLET_'  + Copy(JuncID, 1, 13);
  if Length(COutletID)   > 16 then COutletID   := '_C_OUTLET_'  + Copy(JuncID, 1, 13);
end;

// ---------------------------------------------------------------------------
// Builds the names of the two synthetic curves associated with a demand
// junction: the consumption outlet's rating curve and the withdrawal
// outlet's float-valve control curve. Must stay in sync with
// Uexport.ExportIntermitCurves and Uexport.ExportControlCurves.
// ---------------------------------------------------------------------------
procedure BuildIntermitCurveIDs(const JuncID: String;
  out RatingCurveID, ControlCurveID: String);
begin
  RatingCurveID  := '_DEMAND_' + JuncID;
  ControlCurveID := 'Control'  + JuncID + 'Curve';

  if Length(RatingCurveID) > 16 then
    RatingCurveID := '_DEMAND_' + Copy(JuncID, 1, 13);
  if Length(ControlCurveID) > 16 then
    ControlCurveID := 'Control' + Copy(JuncID, 1, 6) + 'Curve';
end;

// ---------------------------------------------------------------------------
// Returns True when junction N has any intermittent storage defined.
// ---------------------------------------------------------------------------
function JunctionHasIntermitStorage(N: TNode): Boolean;
var
  StorArea, StorHt: Single;
begin
  StorArea := 0;
  StorHt   := 0;
  Uutils.GetSingle(N.Data[JUNCTION_INTERMIT_STOR_AREA_INDEX], StorArea);
  Uutils.GetSingle(N.Data[JUNCTION_INTERMIT_STOR_HT_INDEX],  StorHt);
  Result := (StorArea > 0) or (StorHt > 0);
end;

// ---------------------------------------------------------------------------
// Returns True when junction N is currently a "live" intermittent demand
// node: the user has switched the toggle on AND has defined a storage tank.
// This is the single predicate that should gate generation of the
// synthetic storage/outfall/outlet network - keeping the toggle and the
// tank-size checks bundled together here prevents the two checks from
// drifting apart (which previously let a junction with leftover tank data
// but a toggle set back to NO still generate a (now unreferenced) network).
// ---------------------------------------------------------------------------
function JunctionIsIntermittent(N: TNode): Boolean;
begin
  Result := SameText(Trim(N.Data[JUNCTION_INTERMITTENT_TOGGLE_INDEX]), 'YES')
            and JunctionHasIntermitStorage(N);
end;

// ---------------------------------------------------------------------------
// Returns True if ID matches one of the synthetic object naming prefixes
// used for the intermittent-supply sub-network.
// ---------------------------------------------------------------------------
function IsIntermitGeneratedID(const ID: String): Boolean;
begin
  Result :=
    (Pos('_IS_ST_',     ID) = 1) or
    (Pos('_Outfall_',   ID) = 1) or
    (Pos('_L_Outfall_', ID) = 1) or
    (Pos('W_OUTLET_',   ID) = 1) or
    (Pos('_L_OUTLET_',  ID) = 1) or
    (Pos('_C_OUTLET_',  ID) = 1);
end;

// ---------------------------------------------------------------------------
// Estimates a sensible world-coordinate spacing to lay out the synthetic
// sub-network near its parent junction, based on the overall spread of the
// project's junctions. Falls back to a fixed value if no coordinates are
// available yet (e.g., a brand new project).
// ---------------------------------------------------------------------------
function GetIntermitSpacing: Extended;
var
  I: Integer;
  N: TNode;
  XMin, XMax, YMin, YMax, Diag: Extended;
  HasAny: Boolean;
begin
  HasAny := False;
  XMin := 0; XMax := 0; YMin := 0; YMax := 0;
  with Project.Lists[JUNCTION] do
    for I := 0 to Count - 1 do
    begin
      N := TNode(Objects[I]);
      if (N.X = MISSING) or (N.Y = MISSING) then Continue;
      if not HasAny then
      begin
        XMin := N.X; XMax := N.X; YMin := N.Y; YMax := N.Y;
        HasAny := True;
      end
      else
      begin
        if N.X < XMin then XMin := N.X;
        if N.X > XMax then XMax := N.X;
        if N.Y < YMin then YMin := N.Y;
        if N.Y > YMax then YMax := N.Y;
      end;
    end;

  Result := 10;
  if HasAny then
  begin
    Diag := Sqrt(Sqr(XMax - XMin) + Sqr(YMax - YMin));
    if Diag > 0 then Result := Diag * 0.02;
  end;
end;

// ---------------------------------------------------------------------------
// Positions a synthetic node at a (DX, DY) step offset (in multiples of
// Spacing) from its parent junction, or leaves it unplaced (MISSING) if the
// junction itself has no map coordinates yet.
// ---------------------------------------------------------------------------
procedure PositionSyntheticNode(SynNode, JuncNode: TNode;
  const Spacing: Extended; const DX, DY: Integer);
begin
  if (JuncNode.X = MISSING) or (JuncNode.Y = MISSING) then
  begin
    SynNode.X := MISSING;
    SynNode.Y := MISSING;
  end
  else
  begin
    SynNode.X := JuncNode.X + DX * Spacing;
    SynNode.Y := JuncNode.Y + DY * Spacing;
  end;
end;

// ---------------------------------------------------------------------------
// Finds an existing node of type NType with the given ID, or creates one
// with default properties and adds it to the project.
// ---------------------------------------------------------------------------
function FindOrCreateNode(const NType: Integer; const ID: String): TNode;
var
  Idx: Integer;
begin
  Idx := Project.Lists[NType].IndexOf(ID);
  if Idx >= 0 then
  begin
    Result := TNode(Project.Lists[NType].Objects[Idx]);
    Exit;
  end;

  Result := TNode.Create;
  Result.Ntype := NType;
  Result.X := MISSING;
  Result.Y := MISSING;
  Result.OutFileIndex := -1;
  Result.RptFileIndex := -1;
  Result.ColorIndex := -1;
  Uutils.CopyStringArray(Project.DefProp[NType].Data, Result.Data);

  Project.Lists[NType].AddObject(ID, Result);
  Idx := Project.Lists[NType].Count - 1;
  Result.ID := PChar(Project.Lists[NType].Strings[Idx]);
end;

// ---------------------------------------------------------------------------
// Finds an existing link of type LType with the given ID, or creates one
// with default properties and adds it to the project. Updates the link's
// end nodes in either case, since a junction (or its synthetic nodes) may
// have been recreated between calls.
// ---------------------------------------------------------------------------
function FindOrCreateLink(const LType: Integer; const ID: String;
  Node1, Node2: TNode): TLink;
var
  Idx: Integer;
begin
  Idx := Project.Lists[LType].IndexOf(ID);
  if Idx >= 0 then
  begin
    Result := TLink(Project.Lists[LType].Objects[Idx]);
    Result.Node1 := Node1;
    Result.Node2 := Node2;
    Exit;
  end;

  Result := TLink.Create;
  Result.Ltype := LType;
  Result.Node1 := Node1;
  Result.Node2 := Node2;
  Result.OutFileIndex := -1;
  Result.RptFileIndex := -1;
  Result.ColorIndex := -1;
  Uutils.CopyStringArray(Project.DefProp[LType].Data, Result.Data);

  Project.Lists[LType].AddObject(ID, Result);
  Idx := Project.Lists[LType].Count - 1;
  Result.ID := PChar(Project.Lists[LType].Strings[Idx]);
end;

// ---------------------------------------------------------------------------
// Creates or updates the synthetic storage/outfall/outlet network for a
// single qualifying junction, and records the IDs it uses in the Wanted
// lists so SyncIntermitObjects can prune anything no longer needed.
// ---------------------------------------------------------------------------
procedure SyncOneJunction(N: TNode; const Spacing: Extended;
  WantedStorage, WantedOutfall, WantedOutlet: TStringList);
var
  JuncID, StorageID, OutfallID, LkOutfallID,
  WOutletID, LOutletID, COutletID,
  RatingCurveID, ControlCurveID       : String;
  StorNode, OutfallNode, LkOutfallNode: TNode;
  WOutlet, LOutlet, COutlet          : TLink;
  StorArea, DesiredRate, DesiredPressure,
  MinPressure, Coeff                 : Single;
begin
  JuncID := String(N.ID);
  BuildIntermitIDs(JuncID, StorageID, OutfallID, LkOutfallID,
    WOutletID, LOutletID, COutletID);
  BuildIntermitCurveIDs(JuncID, RatingCurveID, ControlCurveID);

  WantedStorage.Add(StorageID);
  WantedOutfall.Add(OutfallID);
  WantedOutfall.Add(LkOutfallID);
  WantedOutlet.Add(WOutletID);
  WantedOutlet.Add(LOutletID);
  WantedOutlet.Add(COutletID);

  StorArea := 0;
  Uutils.GetSingle(N.Data[JUNCTION_INTERMIT_STOR_AREA_INDEX], StorArea);

  // --- Storage tank (functional shape, constant area = Atank) ---
  StorNode := FindOrCreateNode(STORAGE, StorageID);
  StorNode.Data[NODE_INVERT_INDEX]             := N.Data[NODE_INVERT_INDEX];
  StorNode.Data[STORAGE_MAX_DEPTH_INDEX]       := N.Data[JUNCTION_INTERMIT_STOR_HT_INDEX];
  StorNode.Data[STORAGE_INIT_DEPTH_INDEX]      := N.Data[JUNCTION_INTERMIT_STOR_INIT_DEPTH_INDEX];
  StorNode.Data[STORAGE_SURCHARGE_DEPTH_INDEX] := '0';
  StorNode.Data[STORAGE_GEOMETRY_INDEX]        := 'FUNCTIONAL';
  StorNode.Data[STORAGE_COEFF1_INDEX]          := '0';
  StorNode.Data[STORAGE_COEFF2_INDEX]          := '0';
  StorNode.Data[STORAGE_COEFF0_INDEX]          := Format('%.4f', [StorArea]);
  StorNode.Data[STORAGE_EVAP_FACTOR_INDEX]     := '0';
  PositionSyntheticNode(StorNode, N, Spacing, 1, 0);

  // --- Demand outfall (end of the consumption outlet) ---
  OutfallNode := FindOrCreateNode(OUTFALL, OutfallID);
  OutfallNode.Data[NODE_INVERT_INDEX]       := N.Data[NODE_INVERT_INDEX];
  OutfallNode.Data[OUTFALL_TYPE_INDEX]      := 'FREE';
  OutfallNode.Data[OUTFALL_TIDE_GATE_INDEX] := 'NO';
  OutfallNode.Data[OUTFALL_ROUTETO_INDEX]   := '';
  PositionSyntheticNode(OutfallNode, N, Spacing, 2, 0);

  // --- Leakage outfall (end of the leakage outlet) ---
  LkOutfallNode := FindOrCreateNode(OUTFALL, LkOutfallID);
  LkOutfallNode.Data[NODE_INVERT_INDEX]       := N.Data[NODE_INVERT_INDEX];
  LkOutfallNode.Data[OUTFALL_TYPE_INDEX]      := 'FREE';
  LkOutfallNode.Data[OUTFALL_TIDE_GATE_INDEX] := 'NO';
  LkOutfallNode.Data[OUTFALL_ROUTETO_INDEX]   := '';
  PositionSyntheticNode(LkOutfallNode, N, Spacing, 0, 1);

  // --- Withdrawal outlet: Junction -> Storage tank ---
  DesiredRate := 0; DesiredPressure := 0; MinPressure := 0; Coeff := 0;
  Uutils.GetSingle(N.Data[JUNCTION_INTERMIT_WITHDRAWAL_DESIRED_RATE_INDEX], DesiredRate);
  Uutils.GetSingle(N.Data[JUNCTION_INTERMIT_WITHDRAWAL_DESIRED_PRESSURE_INDEX], DesiredPressure);
  Uutils.GetSingle(N.Data[JUNCTION_INTERMIT_WITHDRAWAL_MIN_PRESSURE_INDEX], MinPressure);
  if DesiredPressure > MinPressure
  then Coeff := DesiredRate / Sqrt(DesiredPressure - MinPressure)
  else Coeff := 0;

  WOutlet := FindOrCreateLink(OUTLET, WOutletID, N, StorNode);
  WOutlet.Data[OUTLET_CREST_INDEX]    := '0';
  WOutlet.Data[OUTLET_TYPE_INDEX]     := 'FUNCTIONAL/DEPTH';
  WOutlet.Data[OUTLET_QCOEFF_INDEX]   := Format('%.6f', [Coeff]);
  WOutlet.Data[OUTLET_QEXPON_INDEX]   := N.Data[JUNCTION_INTERMIT_WITHDRAWAL_EXPONENT_INDEX];
  WOutlet.Data[OUTLET_FLAPGATE_INDEX] := 'YES';

  // --- Leakage outlet: Junction -> Leakage outfall ---
  LOutlet := FindOrCreateLink(OUTLET, LOutletID, N, LkOutfallNode);
  LOutlet.Data[OUTLET_CREST_INDEX]    := '0';
  LOutlet.Data[OUTLET_TYPE_INDEX]     := 'FUNCTIONAL/DEPTH';
  LOutlet.Data[OUTLET_QCOEFF_INDEX]   := N.Data[JUNCTION_LEAKAGE_COEFFICIENT_INDEX];
  LOutlet.Data[OUTLET_QEXPON_INDEX]   := N.Data[JUNCTION_LEAKAGE_EXPONENT_INDEX];
  LOutlet.Data[OUTLET_FLAPGATE_INDEX] := 'YES';

  // --- Consumption outlet: Storage tank -> Demand outfall ---
  COutlet := FindOrCreateLink(OUTLET, COutletID, StorNode, OutfallNode);
  COutlet.Data[OUTLET_CREST_INDEX]    := '0';
  COutlet.Data[OUTLET_TYPE_INDEX]     := 'TABULAR/DEPTH';
  COutlet.Data[OUTLET_QTABLE_INDEX]   := RatingCurveID;
  COutlet.Data[OUTLET_FLAPGATE_INDEX] := 'YES';
end;

// ---------------------------------------------------------------------------
// Removes any synthetic (auto-generated) object of type ObjType whose ID is
// not in the Wanted list - i.e., objects left over from a junction that was
// deleted, renamed, or had its intermittent settings turned off.
// ---------------------------------------------------------------------------
procedure PruneSynthetic(const ObjType: Integer; Wanted: TStringList);
var
  I  : Integer;
  ID : String;
  Obj: TObject;
begin
  with Project.Lists[ObjType] do
    for I := Count - 1 downto 0 do
    begin
      ID := Strings[I];
      if not IsIntermitGeneratedID(ID) then Continue;
      if Wanted.IndexOf(ID) >= 0 then Continue;
      Obj := Objects[I];
      Delete(I);
      if Project.IsLink(ObjType) then TLink(Obj).Free
      else TNode(Obj).Free;
    end;
end;

// ---------------------------------------------------------------------------
// Regenerates the in-memory storage/outfall/outlet network for every
// junction currently flagged as an intermittent demand node, and removes
// any previously-generated objects that no longer apply. Safe to call
// repeatedly (idempotent) - it is invoked before every project export
// (Save and Run) and after a project is opened.
// ---------------------------------------------------------------------------
procedure SyncIntermitObjects;
var
  WantedStorage, WantedOutfall, WantedOutlet: TStringList;
  Spacing: Extended;
  I: Integer;
  N: TNode;
begin
  if Project = nil then Exit;
  if Project.Lists[JUNCTION] = nil then Exit;

  Spacing := GetIntermitSpacing;

  WantedStorage := TStringList.Create;
  WantedOutfall := TStringList.Create;
  WantedOutlet  := TStringList.Create;
  try
    with Project.Lists[JUNCTION] do
      for I := 0 to Count - 1 do
      begin
        N := TNode(Objects[I]);
        if JunctionIsIntermittent(N) then
          SyncOneJunction(N, Spacing, WantedStorage, WantedOutfall, WantedOutlet);
      end;

    // Prune outlet links before their end nodes
    PruneSynthetic(OUTLET,  WantedOutlet);
    PruneSynthetic(STORAGE, WantedStorage);
    PruneSynthetic(OUTFALL, WantedOutfall);
  finally
    WantedStorage.Free;
    WantedOutfall.Free;
    WantedOutlet.Free;
  end;
end;

end.
