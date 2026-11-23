package com.leohearts.ifivesettings;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import android.util.Log;

import java.io.File;
import java.lang.reflect.Method;

/*
 * One-shot repair of /data/media/<user>/Android/{data,obb}/<package> after the 4.19 (sdcardfs)
 * to 6.1 (FUSE only) kernel change.
 *
 * sdcardfs presented app directories with the right owner itself and left the files below on
 * the lower filesystem owned by media_rw (fs/sdcardfs/derived_perm.c fixup_lower_ownership).
 * On FUSE, zygote bind-mounts the lower Android/data/<pkg> into the app, so the app needs the
 * real uid / ext_data_rw gid / project id there, which AOSP vold gives to every directory it
 * creates (Utils.cpp PrepareAppDirFromRoot). The AOSP call that repairs existing directories is
 * IStorageManager.fixupAppDir(path) -> vold VolumeManager::fixupAppDir (no permission check in
 * StorageManagerService). It repairs the directories named in the path and their immediate
 * entries only, so this tool calls it for every leaf directory; each call also repairs all
 * ancestors up to the package directory. Nothing is changed here: the tool only lists the lower
 * filesystem, which an app cannot (Android/data of other apps is hidden from FUSE clients), and
 * asks the framework to do the repair.
 *
 * Run by hand as root through app_process (scripts/fixup-app-dirs.sh), the way AOSP's /system/bin/sm reaches the same
 * service (cmds/sm Sm.java: IStorageManager.Stub.asInterface(ServiceManager.getService("mount"))).
 * ServiceManager and IStorageManager are hidden, so they are called by
 * reflection; a process started by app_process is not subject to hidden API enforcement.
 */
public final class FixupAppDirs {
    private static final String TAG = "IfiveAppDirFix";
    private static final String LOWER = "/data/media";
    private static final String STORAGE = "/storage/emulated";
    private static final String[] AREAS = {"data", "obb"};
    private static final int AID_APP_START = 10000;

    private static Object sm;
    private static Method fixupAppDir;
    private static int calls;
    private static int unfixed;

    public static void main(String[] args) throws Exception {
        Object binder = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "mount");
        if (binder == null) {
            Log.e(TAG, "no mount service");
            System.exit(1);
        }
        sm = Class.forName("android.os.storage.IStorageManager$Stub")
                .getMethod("asInterface", Class.forName("android.os.IBinder")).invoke(null, binder);
        // Looked up on the interface: the Stub.Proxy class behind sm is not public.
        fixupAppDir = Class.forName("android.os.storage.IStorageManager")
                .getMethod("fixupAppDir", String.class);

        File[] users = new File(LOWER).listFiles();
        if (users == null) {
            Log.e(TAG, "cannot list " + LOWER);
            System.exit(1);
        }
        for (File user : users) {
            if (!user.getName().matches("[0-9]+")) continue;
            for (String area : AREAS) {
                File[] pkgs = new File(user, "Android/" + area).listFiles();
                if (pkgs == null) continue;
                for (File pkg : pkgs) {
                    // StorageManagerService rejects packages that are not installed for the user.
                    if (!isDir(pkg) || !new File("/data/user_de/" + user.getName(),
                            pkg.getName()).isDirectory()) continue;
                    fixLeaves(pkg, STORAGE + "/" + user.getName() + "/Android/" + area + "/"
                            + pkg.getName());
                    countUnfixed(pkg);
                }
            }
        }
        String result = "fixupAppDir calls: " + calls + ", entries still owned by a system uid: " + unfixed;
        Log.i(TAG, result);
        System.out.println(result);
    }

    private static void fixLeaves(File dir, String storagePath) throws Exception {
        File[] entries = dir.listFiles();
        boolean leaf = true;
        if (entries != null) {
            for (File e : entries) {
                if (isDir(e)) {
                    leaf = false;
                    fixLeaves(e, storagePath + "/" + e.getName());
                }
            }
        }
        if (leaf) {
            fixupAppDir.invoke(sm, storagePath);
            calls++;
        }
    }

    private static void countUnfixed(File f) {
        try {
            if (Os.lstat(f.getPath()).st_uid < AID_APP_START) unfixed++;
        } catch (ErrnoException e) {
            return;
        }
        File[] entries = isDir(f) ? f.listFiles() : null;
        if (entries != null) {
            for (File e : entries) countUnfixed(e);
        }
    }

    private static boolean isDir(File f) {
        try {
            StructStat st = Os.lstat(f.getPath());
            return OsConstants.S_ISDIR(st.st_mode);
        } catch (ErrnoException e) {
            return false;
        }
    }
}
