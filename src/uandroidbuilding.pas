{-------------------------------------------------------------------------------

Copyright (C) 2015 Helltar <mail@helltar.com>

This file is part of AMPASIDE.

AMPASIDE is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

AMPASIDE is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with AMPASIDE.  If not, see <http://www.gnu.org/licenses/>.

-------------------------------------------------------------------------------}

unit uAndroidBuilding;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil;

type

  { TAndroidBuildingThread }

  TAndroidBuildingThread = class(TThread)
  private
    FAntBuildFile: string;
    function CreateBuildFile(const FileName, JadName, ApkName, Outdir: string): boolean;
    function CreateStringsFile(const FileName, AppName, MainClass, JadName: string): boolean;
    procedure BuildAPK(const AntBuildFile: string);
  protected
    procedure Execute; override;
  public
    constructor Create(CreateSuspended: boolean);
    property AntBuildFile: string write FAntBuildFile;
  end;

resourcestring
  TEXT_COMPILE_PROJECT = 'compile project, it takes about a minute';

implementation

uses
  uAMPASCore,
  uProjectBuilding,
  uProjectConfig,
  uProjectManager;

{ TAndroidBuildingThread }

constructor TAndroidBuildingThread.Create(CreateSuspended: boolean);
begin
  inherited Create(CreateSuspended);
  FreeOnTerminate := True;
end;

procedure TAndroidBuildingThread.Execute;
begin
  BuildAPK(FAntBuildFile);
end;

function TAndroidBuildingThread.CreateStringsFile(const FileName, AppName, MainClass, JadName: string): boolean;
begin
  Result := False;
  with TStringList.Create do
  begin
    try
      Add('<?xml version="1.0" encoding="utf-8"?>');
      Add('<resources>');
      Add('<string name="app_name">' + AppName + '</string>');
      Add('<string name="class_name">' + MainClass + '</string>');
      Add('<string name="jad_name">' + JadName + '</string>');
      Add('</resources>');
      try
        SaveToFile(FileName);
        Result := True;
      except
        AddLogMsg(ERR_FAILED_SAVE + ': ' + FileName, lmtErr);
      end;
    finally
      Free;
    end;
  end;
end;

function TAndroidBuildingThread.CreateBuildFile(const FileName, JadName, ApkName, Outdir: string): boolean;
const
  TAB = LE + '    ';

begin
  Result := False;

  with TStringList.Create do
    try
      try
        LoadFromFile(FileName);
        Insert(1, TAB +
          '<!--- ' + APP_NAME + ' -->' + TAB +
          '<property name="midlet.jad" value="' + JadName + '" />' + TAB +
          '<property name="midlet.package" value="' + ApkName + '" />' + TAB +
          '<property name="outdir" value="' + Outdir + '" />' + TAB +
          '<property name="sdk-folder" value="' + GetAppPath + APP_DIR_ANDROID + 'sdk" />' + TAB +
          '<property name="root-folder" value="' + GetAppPath + APP_DIR_ANDROID + '" />' + TAB +
          '<!--- ' + APP_NAME + ' -->');
      except
        AddLogMsg(ERR_FAILED_DOWNLOAD + ': ' + FileName, lmtErr);
      end;

      try
        SaveToFile(FileName);
        Result := True;
      except
        AddLogMsg(ERR_FAILED_SAVE + ': ' + FileName, lmtErr);
      end;
    finally
      Free;
    end;
end;

procedure TAndroidBuildingThread.BuildAPK(const AntBuildFile: string);
var
  ApkName, MIDletName: string;
  ProjBuildFile: string;

  function PreBuildAct: boolean;
  begin
    Result := False;

    with TProjectBuilding.Create do
      try
        if not Build(True) then
          Exit;
      finally
        Free;
      end;

    if CheckFile(AntBuildFile) then
      if MakeDir(GetAppPath + APP_DIR_TMP) and MakeDir(GetAppPath + APP_DIR_LOGS) then
        if CopyFile(AntBuildFile, ProjBuildFile) then
          if CreateBuildFile(ProjBuildFile, ProjManager.JadFile,
            ApkName, ProjManager.ProjDirPreBuild) then
            if CreateStringsFile(GetAppPath + APP_DIR_TMP + 'strings.xml', MIDletName, 'FW', MIDletName + EXT_JAD) then
              Result := True;
  end;

  procedure DelTempFiles;
  begin
    DeleteFile(ProjBuildFile);
    DeleteDirectory(GetAppPath + APP_DIR_ANDROID + 'src' + DIR_SEP + 'org' + DIR_SEP + 'microemu' + DIR_SEP + 'android' + DIR_SEP + MIDletName, False);
    DeleteDirectory(GetAppPath + APP_DIR_TMP, False);
  end;

var
  ApkFileName: string;
  AntOutput, AntCmd: string;
  P: TProcFunc;

begin
  MIDletName := ProjConfig.MIDletName;
  ProjBuildFile := GetAppPath + APP_DIR_TMP + 'build.' + MIDletName + '.xml';
  ApkName := MIDletName + EXT_APK;

  if not PreBuildAct then
    Exit;

  AddLogMsg('Apache Ant, ' + TEXT_COMPILE_PROJECT + '...' + LE + ProjManager.ProjDirAndroid + ApkName);

  AntCmd := APACHE_ANT + ProjBuildFile;

  {$IFDEF MSWINDOWS}
  AntCmd := AntCmd + ' -logfile ' + GetAppPath + ANT_LOG;
  {$ENDIF}

  P := ProcStart(AntCmd);

  if not P.Completed then
    Exit;

  // ant.log
  if P.Output <> EmptyStr then
    with TStringList.Create do
      try
        Text := P.Output;
        AntOutput := Text;
        SaveToFile(GetAppPath + ANT_LOG);
      finally
        Free;
      end
  else
    with TStringList.Create do
      try
        LoadFromFile(GetAppPath + ANT_LOG);
        AntOutput := Text;
      finally
        Free;
      end;

  if Pos('BUILD SUCCESSFUL', AntOutput) > 0 then
  begin
    AddLogMsg(LOG_INFO_ANT_COMPLETED_WORK + ': .' + DIR_SEP + ANT_LOG);

    ApkFileName := ProjManager.ProjDirPreBuild + ApkName;

    // ../pre-build/midlet.apk -> ../bin/android/midlet.apk
    if RenameFile(ApkFileName, ProjManager.ProjDirAndroid + ApkName) then
      ApkFileName := ProjManager.ApkFile;

    AddLogMsg(MSG_BUILD_SUCCESSFUL + LE +
      TEXT_VERSION + ': ' + ProjManager.MIDletVersion + LE + TEXT_SIZE + ': ' +
      GetFileSize(ApkFileName) + LE + TEXT_PLATFORM + ': Android' + LE +
      PROJ_DIR_BIN + DIR_SEP + PROJ_DIR_ANDROID + DIR_SEP + ApkName, lmtOk);

    DelTempFiles;
  end
  else
    AddLogMsg(ERR_FAILDED_BUILD_APK + ': .' + DIR_SEP + ANT_LOG, lmtErr);
end;

end.
