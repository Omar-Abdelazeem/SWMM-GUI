unit UIntermitDisplay;

interface

uses
  SysUtils, Classes, Uproject, Uglobals, Uutils;

procedure BuildIntermitIDs(const JuncID: String;
  out StorageID, OutfallID, LkOutfallID, WOutletID, COutletID: String);

function JunctionHasIntermitStorage(N: TNode): Boolean;

implementation

// ---------------------------------------------------------------------------
// ID builder
// Naming conventions must stay in sync with Uexport.pas and Uimport.pas:
//   Storage   : '_IS_ST_'  + JuncID  (skip if >16 chars)
//   Outfall   : '_Outfall_'  + JuncID
//   LkOutfall : '_L_Outfall' + JuncID
//   WOutlet   : 'W_OUTLET_'+ JuncID
//   COutlet   : 'C_OUT_'   + JuncID   (consumption outlet)
// ---------------------------------------------------------------------------
procedure BuildIntermitIDs(const JuncID: String;
  out StorageID, OutfallID, LkOutfallID, WOutletID, COutletID: String);
begin
  StorageID   := '_IS_ST_'   + JuncID;
  OutfallID   := '_IS_OF_'   + JuncID;
  LkOutfallID := '_IS_LOF_'  + JuncID;
  WOutletID   := 'W_OUTLET_' + JuncID;
  COutletID   := 'C_OUT_'    + JuncID;

  if Length(StorageID)   > 16 then StorageID   := '_IS_ST_'   + Copy(JuncID, 1, 9);
  if Length(OutfallID)   > 16 then OutfallID   := '_Outfall_'   + Copy(JuncID, 1, 9);
  if Length(LkOutfallID) > 16 then LkOutfallID := '_L_Outfall_'  + Copy(JuncID, 1, 8);
  if Length(WOutletID)   > 16 then WOutletID   := 'W_OUTLET_' + Copy(JuncID, 1, 7);
  if Length(COutletID)   > 16 then COutletID   := 'C_OUT_'    + Copy(JuncID, 1, 10);
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

end.
