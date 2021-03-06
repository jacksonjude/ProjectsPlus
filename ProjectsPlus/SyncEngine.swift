//
//  SyncEngine.swift
//  ProjectsPlus
//
//  Created by jackson on 8/21/15.
//  Copyright (c) 2015 jackson. All rights reserved.
//

import Foundation
import CoreData
import CloudKit
import UIKit

class SyncEngine: NSObject, NSFetchedResultsControllerDelegate
{
    let kIsSynced = 1
    let kNeedsSync = 0
    
    var justCompletedSync = false
        
    let remoteSubscriptions = NSMutableDictionary()
    let localFetchedResultsController = NSMutableArray()
    
    var managedObjectContext: NSManagedObjectContext = {
        var managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.parentContext = AppDelegate.sharedAppDelegate().managedObjectContext
        //managedObjectContext.parentContext = AppDelegate.sharedAppDelegate().masterController?.managedObjectContext!
        return managedObjectContext
    }()
    
    func setupLocalFetchedResultsController()
    {
        let fetchRequest = NSFetchRequest()
        // Edit the entity name as appropriate.
        let entity = NSEntityDescription.entityForName("Project", inManagedObjectContext: self.managedObjectContext)
        fetchRequest.entity = entity
        
        // Set the batch size to a suitable number.
        fetchRequest.fetchBatchSize = 20
        
        // Edit the sort key as appropriate.
        let sortDescriptor = NSSortDescriptor(key: "dueDate", ascending: true)
        
        fetchRequest.sortDescriptors = [sortDescriptor]
        
        let predicate = NSPredicate(format: "syncState == %i", self.kNeedsSync)
        fetchRequest.predicate = predicate
        
        // Edit the section name key path and cache name if appropriate.
        // nil for section name key path means "no sections".
        let projectsFetchedResultsController = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: self.managedObjectContext, sectionNameKeyPath: nil, cacheName: nil)
        projectsFetchedResultsController.delegate = self
        
        self.managedObjectContext.performBlockAndWait
            {
                var error: NSError? = nil
                do {
                    try projectsFetchedResultsController.performFetch()
                } catch let error1 as NSError {
                    error = error1
                    print("Unresolved error \(error), \(error!.userInfo)")
                } catch {
                    fatalError()
                }
        }
        self.localFetchedResultsController.addObject(projectsFetchedResultsController)
        
        
        let taskFetchRequest = NSFetchRequest()
        // Edit the entity name as appropriate.
        let taskEntity = NSEntityDescription.entityForName("Task", inManagedObjectContext: self.managedObjectContext)
        taskFetchRequest.entity = taskEntity
        
        // Set the batch size to a suitable number.
        taskFetchRequest.fetchBatchSize = 20
        
        // Edit the sort key as appropriate.
        let sortDescriptor2 = NSSortDescriptor(key: "completionStatus", ascending: true)
        
        taskFetchRequest.sortDescriptors = [sortDescriptor2]
        
        taskFetchRequest.predicate = predicate
        
        // Edit the section name key path and cache name if appropriate.
        // nil for section name key path means "no sections".
        let tasksFetchedResultsController = NSFetchedResultsController(fetchRequest: taskFetchRequest, managedObjectContext: self.managedObjectContext, sectionNameKeyPath: nil, cacheName: nil)
        tasksFetchedResultsController.delegate = self
        
        self.managedObjectContext.performBlockAndWait
            {
                var error: NSError? = nil
                do {
                    try tasksFetchedResultsController.performFetch()
                } catch let error1 as NSError {
                    error = error1
                    print("Unresolved error \(error), \(error!.userInfo)")
                } catch {
                    fatalError()
                }
        }
        self.localFetchedResultsController.addObject(tasksFetchedResultsController)
    }
    
    @objc func controller(controller: NSFetchedResultsController, didChangeObject anObject: AnyObject, atIndexPath indexPath: NSIndexPath?, forChangeType type: NSFetchedResultsChangeType, newIndexPath: NSIndexPath?)
    {
        let aLocalRecord = anObject as! Syncable
        let entityType = NSStringFromClass(anObject.classForCoder)
        let privateDatabase = CKContainer.defaultContainer().privateCloudDatabase
        
        if self.justCompletedSync == true
        {
            self.justCompletedSync = false
        }
        else
        {
            switch type
            {
                case .Insert:
                    let fetchRequest = NSFetchRequest(entityName: entityType)
                    
                    // Create a new predicate that filters out any object that
                    // doesn't have a title of "Best Language" exactly.
                    let predicate = NSPredicate(format: "syncState == %i", self.kNeedsSync)
                    
                    // Set the predicate on the fetch request
                    fetchRequest.predicate = predicate
                    
                    let fetchResults: [AnyObject]?
                    var error: NSError? = nil
                    
                    do {
                        fetchResults = try self.managedObjectContext.executeFetchRequest(fetchRequest) as? [Syncable]
                    } catch let error1 as NSError {
                        error = error1
                        fetchResults = nil
                    } catch {
                        fatalError()
                    }
                    if error != nil
                    {
                        NSLog("An Error Occored:", error!)
                    }
                    else
                    {
                        NSLog("Fetched Objects To Update From CoreData...")
                    }
                    for addedRecord in fetchResults! as! [Syncable]
                    {
                        ///////
                        
                        if addedRecord.syncState == self.kNeedsSync
                        {
                            
                            let remoteID = CKRecordID(recordName: addedRecord.uuid!)
                            
                            let remoteRecord = CKRecord(recordType: entityType, recordID: remoteID)
                            
                            addedRecord.updateToRemote(remoteRecord)
                            
                            let privateDatabase = CKContainer.defaultContainer().privateCloudDatabase
                            
                            privateDatabase.saveRecord(remoteRecord, completionHandler: { (record, error) -> Void in
                                if (error != nil) {
                                    NSLog("Error: \(error)")
                                }
                                else
                                {
                                    self.managedObjectContext.performBlock
                                        {
                                            var newError: NSError? = nil
                                            
                                            addedRecord.syncState = self.kIsSynced
                                            
                                            self.justCompletedSync = true
                                            
                                            do {
                                                try self.managedObjectContext.save()
                                            } catch let error as NSError {
                                                newError = error
                                                NSLog("%@", newError!)
                                            } catch {
                                                fatalError()
                                            }
                                    }
                                }
                            })
                        }
                    }
                case .Delete:
                    NSLog(aLocalRecord.uuid!)
                    let deletedRecordUUID = aLocalRecord.uuid
                    let query = CKQuery(recordType: entityType, predicate: NSPredicate(format: "uuid == %@", aLocalRecord.uuid!))
                    privateDatabase.performQuery(query, inZoneWithID: CKRecordZone.defaultRecordZone().zoneID, completionHandler:
                    { (results, error) -> Void in
                        if error != nil
                        {
                            NSLog("Error:%@", error!)
                        }
                        else
                        {
                            if results!.first != nil
                            {
                                privateDatabase.deleteRecordWithID(CKRecordID(recordName: deletedRecordUUID!), completionHandler: { (recordID, newError) -> Void in
                                    if newError != nil
                                    {
                                        var newError: NSError? = nil
                                        
                                        aLocalRecord.syncState = self.kIsSynced
                                        
                                        self.justCompletedSync = true
                                        
                                        do {
                                            try self.managedObjectContext.save()
                                        } catch let error as NSError {
                                            newError = error
                                            NSLog("%@", newError!)
                                        } catch {
                                            fatalError()
                                        }
                                    }
                                })
                            }
                        }
                    })
                case .Update:
                    self.justSaved(aLocalRecord, entityType: entityType)
                case .Move:
                    self.justSaved(aLocalRecord, entityType: entityType)
            }
        }
    }
    
    func justSaved(localRecord: Syncable, entityType: String)
    {
        let privateDatabase = CKContainer.defaultContainer().privateCloudDatabase
        let query = CKQuery(recordType: entityType, predicate: NSPredicate(format: "uuid == %@", localRecord.uuid!))
        privateDatabase.performQuery(query, inZoneWithID: CKRecordZone.defaultRecordZone().zoneID, completionHandler:
            { (results, error) -> Void in
                if error != nil
                {
                    NSLog("Error:%@", error!)
                }
                else
                {
                    if results?.count > 0
                    {
                        let remoteRecord = (results?.first)! as CKRecord
                        
                        localRecord.updateToRemote(remoteRecord)
                        
                        privateDatabase.saveRecord(remoteRecord, completionHandler: { (record, error) -> Void in
                            if (error != nil) {
                                //NSLog("Error: \(error)")
                            }
                            else
                            {
                                self.managedObjectContext.performBlock
                                    {
                                        var newError: NSError? = nil
                                        
                                        localRecord.syncState = self.kIsSynced
                                        
                                        self.justCompletedSync = true
                                        
                                        do {
                                            try self.managedObjectContext.save()
                                        } catch let error as NSError {
                                            newError = error
                                            NSLog("%@", newError!)
                                        } catch {
                                            fatalError()
                                        }
                                }
                            }
                        })
                    }
                    else
                    {
                        let fetchRequest = NSFetchRequest(entityName: entityType)
                        
                        // Create a new predicate that filters out any object that
                        // doesn't have a title of "Best Language" exactly.
                        let predicate = NSPredicate(format: "syncState == %i", self.kNeedsSync)
                        
                        // Set the predicate on the fetch request
                        fetchRequest.predicate = predicate
                        
                        let fetchResults: [AnyObject]?
                        var error: NSError? = nil
                        
                        do {
                            fetchResults = try self.managedObjectContext.executeFetchRequest(fetchRequest) as? [Syncable]
                        } catch let error1 as NSError {
                            error = error1
                            fetchResults = nil
                        } catch {
                            fatalError()
                        }
                        if error != nil
                        {
                            NSLog("An Error Occored:", error!)
                        }
                        else
                        {
                            NSLog("Fetched Objects To Update From CoreData...")
                        }
                        for localRecord in fetchResults! as! [Syncable]
                        {
                            ///////
                            
                            if localRecord.syncState == self.kNeedsSync
                            {
                                
                                let remoteID = CKRecordID(recordName: localRecord.uuid!)
                                
                                let remoteRecord = CKRecord(recordType: entityType, recordID: remoteID)
                                
                                localRecord.updateToRemote(remoteRecord)
                                
                                let privateDatabase = CKContainer.defaultContainer().privateCloudDatabase
                                
                                privateDatabase.saveRecord(remoteRecord, completionHandler: { (record, error) -> Void in
                                    if (error != nil) {
                                        //NSLog("Error: \(error)")
                                    }
                                    else
                                    {
                                        self.managedObjectContext.performBlock
                                            {
                                                var newError: NSError? = nil
                                                
                                                localRecord.syncState = self.kIsSynced
                                                
                                                self.justCompletedSync = true
                                                
                                                do {
                                                    try self.managedObjectContext.save()
                                                } catch let error as NSError {
                                                    newError = error
                                                    NSLog("%@", newError!)
                                                } catch {
                                                    fatalError()
                                                }
                                        }
                                    }
                                })
                            }
                        }
                    }
                }
        })
    }
    
    func setupRemoteSubscriptions()
    {
        let privateDatabase = CKContainer.defaultContainer().privateCloudDatabase as CKDatabase
        privateDatabase.fetchAllSubscriptionsWithCompletionHandler { (remoteSubscriptions, remoteError) -> Void in
            
            if (remoteSubscriptions!.count > 0)
            {
                // deeje 2015-11-27 this never gets called… ?!?!?
                for remoteSubscription in remoteSubscriptions!
                {
                    self.remoteSubscriptions.setObject(remoteSubscription.recordType!, forKey: remoteSubscription.subscriptionID)
                }
            }
            else
            {
                let predicate = NSPredicate(format: "TRUEPREDICATE")
                
                let notificationInfo = CKNotificationInfo()
                notificationInfo.alertLocalizationKey = "Updates In Cloud"
                notificationInfo.shouldBadge = false
                
                let projectSubscription = CKSubscription(recordType: "Project",
                    predicate: predicate,
                    options: [.FiresOnRecordCreation, .FiresOnRecordUpdate, .FiresOnRecordDeletion])
                projectSubscription.notificationInfo = notificationInfo
                privateDatabase.saveSubscription(projectSubscription, completionHandler: { ( subscription, error) -> Void in
                    if error != nil
                    {
                        NSLog("An error occured in saving subscription: \(error)")
                    }
                    else
                    {
                        NSLog("Saved Subscription Succesfully")
                        
                        self.remoteSubscriptions.setObject("Project", forKey: (subscription?.subscriptionID)!)
                    }
                })
                
                let taskSubscription = CKSubscription(recordType: "Task",
                    predicate: predicate,
                    options: [.FiresOnRecordCreation, .FiresOnRecordUpdate, .FiresOnRecordDeletion])
                taskSubscription.notificationInfo = notificationInfo
                privateDatabase.saveSubscription(taskSubscription, completionHandler: { ( subscription, error) -> Void in
                    if error != nil
                    {
                        NSLog("An error occured in saving subscription: \(error)")
                    }
                    else
                    {
                        NSLog("Saved Subscription Succesfully")
                        
                        self.remoteSubscriptions.setObject("Task", forKey: (subscription?.subscriptionID)!)
                    }
                })
            }
        }
    }
    
    func handleRemoteNotifications(userInfo: [NSObject : AnyObject])
    {
        let cloudKitNotification = CKNotification(fromRemoteNotificationDictionary: userInfo as! [String:NSObject])
        if (cloudKitNotification.notificationType == CKNotificationType.Query)
        {
            let privateDatabase = CKContainer.defaultContainer().privateCloudDatabase as CKDatabase
            
            let cloudKitQueryNotification: CKQueryNotification = (cloudKitNotification as? CKQueryNotification)!
            let recordID = cloudKitQueryNotification.recordID
            
            //let fetchRecordChangesOperation = CKFetchRecordChangesOperation(CKRecordZoneID())
            
            switch cloudKitQueryNotification.queryNotificationReason
            {
            case .RecordCreated:
                privateDatabase.fetchRecordWithID(recordID!, completionHandler: { (remoteRecord, error) -> Void in
                    if error != nil
                    {
                        NSLog("An error occured: \(error)")
                    }
                    else
                    {
                        let entityType = remoteRecord?.recordType
                        
                        self.managedObjectContext.performBlock({
                            
                            NSLog("Fetched Record Successfully From Cloud...")
                            let objectUUID = remoteRecord!.objectForKey("uuid") as? String
                            
                            let fetch = NSFetchRequest(entityName: entityType!)
                            let predicate = NSPredicate(format: "uuid = %@", objectUUID!)
                            fetch.predicate = predicate
                            var error: NSError? = nil
                            
                            let results: [AnyObject]?
                            do {
                                results = try self.managedObjectContext.executeFetchRequest(fetch)
                            } catch let error1 as NSError {
                                error = error1
                                results = nil
                            } catch {
                                fatalError()
                            }
                            if error != nil
                            {
                                NSLog("An Error Occored:", error!)
                            }
                            else
                            {
                                NSLog("Fetched Any Duplicate Objects Successfully From CoreData...")
                            }
                            
                            var createdRecord: Syncable? = nil
                            
                            if results?.count == 0
                            {
                                createdRecord = NSEntityDescription.insertNewObjectForEntityForName(entityType!, inManagedObjectContext: self.managedObjectContext) as? Syncable
                                UIApplication.sharedApplication().applicationIconBadgeNumber++
                            }
                            else
                            {
                                createdRecord = results?.first as? Syncable
                            }
                            
                            createdRecord!.updateFromRemote(remoteRecord!)
                            
                            var anError: NSError? = nil
                            do {
                                try self.managedObjectContext.save()
                            } catch let error as NSError {
                                anError = error
                                NSLog("An error occured: \(anError)")
                            } catch {
                                fatalError()
                            }
                        })
                    }
                })
            case .RecordUpdated:
                privateDatabase.fetchRecordWithID(recordID!, completionHandler: { (remoteRecord, error) -> Void in
                    if error != nil
                    {
                        NSLog("An error occured: \(error)")
                    }
                    else
                    {
                        let entityType = remoteRecord?.recordType
                        
                        self.managedObjectContext.performBlock({
                            let fetch = NSFetchRequest(entityName: entityType!)
                            let predicate = NSPredicate(format: "uuid = %@", recordID!.recordName)
                            fetch.predicate = predicate
                            var error: NSError? = nil
                            
                            let results: [AnyObject]?
                            do {
                                results = try self.managedObjectContext.executeFetchRequest(fetch)
                            } catch let error1 as NSError {
                                error = error1
                                results = nil
                            } catch {
                                fatalError()
                            }
                            if error != nil
                            {
                                NSLog("An Error Occored:", error!)
                            }
                            else
                            {
                                NSLog("Fetched Objects To Update From CoreData...")
                            }
                            
                            if results?.count > 0
                            {
                                let updatedRecord = results?.first as? Syncable
                                
                                updatedRecord?.updateFromRemote(remoteRecord!)
                                
                                var error3: NSError? = nil
                                
                                do {
                                    try self.managedObjectContext.save()
                                } catch let error as NSError {
                                    error3 = error
                                    NSLog("An Error Occored:", error3!)
                                } catch {
                                    fatalError()
                                }
                            }
                            else
                            {
                                NSLog("No Record Exists")
                            }
                        })
                    }
                })
            case .RecordDeleted:
                self.managedObjectContext.performBlock({
                    
                    // 2015-11-27 deeje, we can't figure out how to determine which entity type from just the CKNotification
                    let entityTypes = ["Project", "Task"]
                    
                    for entityType in entityTypes
                    {
                        let fetch = NSFetchRequest(entityName: entityType)
                        let predicate = NSPredicate(format: "uuid = %@", recordID!.recordName)
                        fetch.predicate = predicate
                        var error: NSError? = nil
                        
                        let results: [AnyObject]?
                        do {
                            results = try self.managedObjectContext.executeFetchRequest(fetch)
                        } catch let error1 as NSError {
                            error = error1
                            results = nil
                        } catch {
                            fatalError()
                        }
                        if error != nil
                        {
                            NSLog("An Error Occored:", error!)
                        }
                        else
                        {
                            NSLog("Fetched Objects To Delete From CoreData...")
                        }
                        
                        if results?.count > 0
                        {
                            self.managedObjectContext.deleteObject((results?.first! as? NSManagedObject)!)
                        }
                        else
                        {
                            NSLog("No Record Exists")
                        }
                    }
                    
                    self.justCompletedSync = true
                    
                    var error2: NSError?  = nil
                    do {
                        try self.managedObjectContext.save()
                    } catch let error as NSError {
                        error2 = error
                        NSLog("An Error Occored:", error2!)
                    } catch {
                        fatalError()
                    }
                })
            }
        }
    }
    
    func fetchObjects(entity: String, sortDescriptorInput: String, predicate: NSPredicate) -> [AnyObject]
    {
        let taskFetchRequest = NSFetchRequest()
        let taskEntity = NSEntityDescription.entityForName(entity, inManagedObjectContext: self.managedObjectContext)
        taskFetchRequest.entity = taskEntity
        taskFetchRequest.fetchBatchSize = 20
        let sortDescriptor = NSSortDescriptor(key: sortDescriptorInput, ascending: true)
        taskFetchRequest.sortDescriptors = [sortDescriptor]
        //let predicate = NSPredicate(format: "syncState == %i", self.kNeedsSync)
        taskFetchRequest.predicate = predicate
        let tasksFetchedResultsController = NSFetchedResultsController(fetchRequest: taskFetchRequest, managedObjectContext: self.managedObjectContext, sectionNameKeyPath: nil, cacheName: nil)
        tasksFetchedResultsController.delegate = self
        
        self.managedObjectContext.performBlockAndWait
            {
                var error: NSError? = nil
                do {
                    try tasksFetchedResultsController.performFetch()
                } catch let error1 as NSError {
                    error = error1
                    print("Unresolved error \(error), \(error!.userInfo)")
                } catch {
                    fatalError()
                }
        }
        if tasksFetchedResultsController.fetchedObjects != nil
        {
            return tasksFetchedResultsController.fetchedObjects!
        }
        else
        {
            return []
        }
    }
    
    override init()
    {
        super.init()
        
        self.setupLocalFetchedResultsController()
        
        NSNotificationCenter.defaultCenter().addObserverForName(NSManagedObjectContextDidSaveNotification, object: nil, queue: nil) { (notification) -> Void in
            let sender = notification.object as! NSManagedObjectContext
            if sender !== self.managedObjectContext
            {
                self.managedObjectContext.mergeChangesFromContextDidSaveNotification(notification)
            }
        }
        
        NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationDidEnterBackgroundNotification, object: nil, queue: nil) { (notification) -> Void in
            var error: NSError? = nil
            do {
                try self.managedObjectContext.save()
            } catch let error1 as NSError {
                error = error1
                print("Unresolved error \(error), \(error!.userInfo)")
            } catch {
                fatalError()
            }
        }
        
        self.setupRemoteSubscriptions()
    }
    
}